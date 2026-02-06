//
//  UpdateChecker.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation
import AppKit

struct ReleaseInfo: Codable {
    let tagName: String
    let htmlUrl: String
    let body: String
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
    }
}

class UpdateChecker {
    static let shared = UpdateChecker()
    
    // Replace with your actual repo details
    private let repoOwner = "wzh4869"
    private let repoName = "AppPorts"
    
    private init() {}
    
    func checkForUpdates() async throws -> ReleaseInfo? {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // It's good practice to set a User-Agent
        request.addValue("AppPorts-UpdateChecker", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "UpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from GitHub"])
        }
        
        let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        
        if isNewer(tagName: release.tagName) {
            return release
        }
        
        return nil
    }
    
    private func isNewer(tagName: String) -> Bool {
        // Assume tag format is "v1.2.3" or "1.2.3"
        let versionString = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return false }
        
        return compareVersions(versionString, currentVersion) == .orderedDescending
    }
    
    private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }
        
        let count = max(components1.count, components2.count)
        
        for i in 0..<count {
            let num1 = i < components1.count ? components1[i] : 0
            let num2 = i < components2.count ? components2[i] : 0
            
            if num1 > num2 { return .orderedDescending }
            if num1 < num2 { return .orderedAscending }
        }
        
        return .orderedSame
    }
}
