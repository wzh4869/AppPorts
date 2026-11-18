#!/usr/bin/env python3
"""Validate migration, reconnection and restore on a private APFS image.

Without --run this prints the plan and does not create or mount anything.
Compile the test first using the root agent's normal build. This coordinator
uses test-without-building, a fresh NSTemporaryDirectory fixture, real disk
commands, and no administrator prompts. Success detaches only the verified
owned image. Failure preserves the image, attachment, and every data file.
Neither outcome deletes a fixture or changes global ownership settings.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import uuid


SELECTOR = "AppPortsTests/AppPortsRealMountValidationTests/testPrivateAPFSMountMigrationAndRestore"


def identity(path):
    value = os.lstat(path)
    return {"device": value.st_dev & 0xFFFFFFFF, "inode": value.st_ino,
            "uid": value.st_uid, "kind": stat.S_IFMT(value.st_mode)}


def write_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RuntimeError(f"Refusing a non-regular checkpoint: {path}")
    os.replace(temporary, path)


def read_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        value = os.fstat(source.fileno())
        if not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid() or value.st_size > 65536:
            raise RuntimeError(f"Not a small owned checkpoint: {path}")
        return json.load(source)


class Coordinator:
    def __init__(self, repository, image_gib=1):
        self.repository = repository
        self.image_gib = image_gib
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.output = repository / "build/Validation" / ("v3-real-mount-" + stamp + "-" + uuid.uuid4().hex[:8])
        self.output.mkdir(parents=True, mode=0o700)
        self.commands = []
        self.fixture = None

    def command(self, label, arguments, *, timeout=90, environment=None):
        number = len(self.commands) + 1
        output = self.output / f"{number:02d}-{label}.stdout"
        errors = self.output / f"{number:02d}-{label}.stderr"
        record = {"label": label, "arguments": list(map(str, arguments)),
                  "stdout": output.name, "stderr": errors.name}
        self.commands.append(record)
        try:
            with output.open("xb") as out, errors.open("xb") as err:
                result = subprocess.run(arguments, cwd=self.repository, stdin=subprocess.DEVNULL,
                    stdout=out, stderr=err, env=environment, timeout=timeout, check=False)
            record["returnCode"] = result.returncode
            if result.returncode != 0:
                detail = errors.read_text(errors="replace")[-4000:]
                raise RuntimeError(f"{label} exited {result.returncode}: {detail}")
            return output.read_bytes()
        except subprocess.TimeoutExpired:
            record["timedOut"] = True
            raise RuntimeError(f"{label} timed out. The fixture and attachment remain for inspection.")
        finally:
            write_json(self.output / "commands.json", self.commands)

    def require_owned_files(self):
        record = self.fixture
        for path, field, kind in [(Path(record["rootPath"]), "rootIdentity", stat.S_IFDIR),
                                  (Path(record["imagePath"]), "imageIdentity", stat.S_IFREG)]:
            if identity(path) != record[field] or record[field]["kind"] != kind or record[field]["uid"] != os.getuid():
                raise RuntimeError("The owned fixture root or image changed")

    def inventory(self):
        self.require_owned_files()
        record = self.fixture
        image = Path(record["imagePath"])
        info = plistlib.loads(self.command("hdiutil-info", ["/usr/bin/hdiutil", "info", "-plist"]))
        matches = [entry for entry in info.get("images", [])
                   if entry.get("image-path") and Path(entry["image-path"]).resolve() == image]
        if len(matches) != 1:
            raise RuntimeError("The image has no unique live hdiutil attachment")
        devices = {entry.get("dev-entry", "").removeprefix("/dev/")
                   for entry in matches[0].get("system-entities", [])}
        listing = plistlib.loads(self.command("private-apfs-list", ["/usr/sbin/diskutil", "apfs", "list", "-plist", record["containerReference"]]))
        containers = listing.get("Containers", [])
        if len(containers) != 1:
            raise RuntimeError("The APFS container became unavailable or ambiguous")
        container = containers[0]
        stores = {entry.get("DeviceIdentifier", "") for entry in container.get("PhysicalStores", [])}
        if container.get("ContainerReference") != record["containerReference"] \
                or container.get("APFSContainerUUID", "").upper() != record["containerUUID"].upper() \
                or not stores or not stores.issubset(devices):
            raise RuntimeError("The APFS container is not backed exclusively by the owned image")
        self.require_owned_files()
        return container

    def prepare(self):
        temporary = Path(self.command("darwin-user-temp", ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"]).decode().strip()).resolve(strict=True)
        if not temporary.is_dir() or temporary.stat().st_uid != os.getuid():
            raise RuntimeError("The current user's Darwin temporary directory is unavailable")
        space = os.statvfs(temporary)
        if space.f_bavail * space.f_frsize < 1024 ** 3:
            raise RuntimeError("At least 1 GiB of free space is required for the disposable fixture")
        nonce = str(uuid.uuid4()).upper()
        root = temporary / ("AppPortsRealMount-" + nonce)
        root.mkdir(mode=0o700)
        external = root / "External"
        external.mkdir(mode=0o700)
        image = root / "fixture.sparseimage"
        self.fixture = {"nonce": nonce, "rootPath": str(root), "imagePath": str(image),
                        "externalPath": str(external), "rootIdentity": identity(root)}
        write_json(self.output / "fixture.json", self.fixture)
        print(json.dumps({"fixtureRoot": str(root), "artifacts": str(self.output)}), flush=True)
        self.command("hdiutil-create", ["/usr/bin/hdiutil", "create", "-size", f"{self.image_gib}g", "-type", "SPARSE",
            "-fs", "APFS", "-volname", "AppPortsPrivateMount", str(image)], timeout=180)
        self.fixture["imageIdentity"] = identity(image)
        self.require_owned_files()
        self.command("hdiutil-attach", ["/usr/bin/hdiutil", "attach", "-nobrowse", "-owners", "off",
            "-mountpoint", str(external), "-plist", str(image)])
        volume = plistlib.loads(self.command("external-volume-info", ["/usr/sbin/diskutil", "info", "-plist", str(external)]))
        reference = volume.get("APFSContainerReference", "")
        if volume.get("FilesystemType", "").lower() != "apfs" or volume.get("GlobalPermissionsEnabled") is not False \
                or Path(volume.get("MountPoint", "")).resolve() != external or not re.fullmatch(r"disk[0-9]+", reference) \
                or os.stat(external).st_dev == os.stat(root).st_dev:
            raise RuntimeError("The new image is not the expected separately mounted noowners APFS fixture")
        listing = plistlib.loads(self.command("created-container-info", ["/usr/sbin/diskutil", "apfs", "list", "-plist", reference]))
        containers = listing.get("Containers", [])
        if len(containers) != 1 or len(containers[0].get("Volumes", [])) != 1:
            raise RuntimeError("The new image did not contain exactly one APFS container and volume")
        self.fixture.update({"containerReference": reference, "containerUUID": containers[0]["APFSContainerUUID"],
            "initialVolumeUUID": volume["VolumeUUID"], "initialVolumeDevice": volume["DeviceIdentifier"]})
        self.inventory()
        sentinel = os.open(external / "coordinator-sentinel.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(sentinel, "w", encoding="utf-8") as output:
            output.write(nonce)
            output.flush()
            os.fsync(output.fileno())
        write_json(root / "coordinator-owner.json", self.fixture)
        write_json(self.output / "fixture.json", self.fixture)

    def execute(self, derived_data, timeout):
        self.prepare()
        environment = os.environ.copy()
        environment["APPPORTS_REAL_MOUNT_ROOT"] = self.fixture["rootPath"]
        environment["TEST_RUNNER_APPPORTS_REAL_MOUNT_ROOT"] = self.fixture["rootPath"]
        run_file = derived_data / "Build/Products/LifecycleValidation.xctestrun"
        if not run_file.is_file():
            raise RuntimeError("Run script/isolate_test_host.py before real-volume validation")
        arguments = ["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(run_file),
            "-destination", "platform=macOS,arch=arm64", "-jobs", "2", "-parallel-testing-enabled", "NO",
            "-resultBundlePath", str(self.output / "test.xcresult"), "-only-testing:" + SELECTOR]
        self.command("xcodebuild", arguments, timeout=timeout, environment=environment)
        result = read_json(Path(self.fixture["rootPath"]) / "real-mount-result.json")
        required = ["realKernelMountVerified", "activeWritesRestored", "dedicatedVolumeDeleted",
                    "recordsAndMaterialsCleaned", "immutableAbsent", "baseVolumeRemainsNoowners",
                    "reconnectedCurrentData", "permissionDenialPreservesUsableMountAndCanRetry",
                    "permissionLossAfterCopyPreservesLatestData"]
        if result.get("status") != "passed" or result.get("nonce") != self.fixture["nonce"] \
                or any(result.get(key) is not True for key in required):
            raise RuntimeError("The native test did not produce a complete passing result")
        final = self.inventory()
        volumes = final.get("Volumes", [])
        if len(volumes) != 1 or volumes[0].get("APFSVolumeUUID", "").upper() != self.fixture["initialVolumeUUID"].upper() \
                or volumes[0].get("DeviceIdentifier") != self.fixture["initialVolumeDevice"]:
            raise RuntimeError("Unexpected volumes remain; preserving the attachment for inspection")
        # No force, no broad disk lookup, and no fixture deletion.
        self.command("hdiutil-detach-owned-image", ["/usr/bin/hdiutil", "detach", "/dev/" + self.fixture["initialVolumeDevice"]])
        result.update({"imageDetached": True, "fixtureRoot": self.fixture["rootPath"], "artifacts": str(self.output)})
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--derived-data", type=Path, default=Path("build/APFSRestorePermissions"))
    parser.add_argument("--timeout", type=float, default=900)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    if not (repository / "AppPorts.xcodeproj").is_dir() or args.timeout <= 0:
        parser.error("Keep this coordinator in script and use a positive timeout")
    derived_data = args.derived_data.expanduser().resolve()
    if not args.run:
        print(json.dumps({"mode": "plan only", "selector": SELECTOR, "derivedData": str(derived_data),
            "fixture": "Fresh AppPortsRealMount-UUID under DARWIN_USER_TEMP_DIR; 1 GiB sparse APFS image; owners off",
            "prerequisite": "Root-coordinated build must include AppPortsRealMountValidationTests",
            "success": "Verify full native result and exact image/container, then detach only that image",
            "failure": "Retain all files and the private attachment; no global policy changes"}, indent=2))
        return 0
    if sys.platform != "darwin" or not (derived_data / "Build/Products/Debug/AppPorts.app").is_dir():
        parser.error("A prebuilt macOS AppPorts test host is required")
    coordinator = Coordinator(repository)
    try:
        result = coordinator.execute(derived_data, args.timeout)
        status = 0
    except Exception as error:
        result = {"status": "failed", "error": str(error), "fixture": coordinator.fixture,
                  "artifacts": str(coordinator.output), "retainedForInspection": True}
        status = 1
    write_json(coordinator.output / "summary.json", result)
    print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
