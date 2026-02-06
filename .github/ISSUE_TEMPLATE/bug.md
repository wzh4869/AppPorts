name: "🐛 Bug / 问题反馈"
description: "Report a bug / 反馈一个问题"
title: "[BUG] "
labels: ["bug"]
body:
  - type: textarea
    id: problem
    attributes:
      label: "Problem / 问题描述"
      placeholder: "请清楚描述你遇到的问题 / Describe the issue clearly"
    validations:
      required: true

  - type: textarea
    id: steps
    attributes:
      label: "Steps to Reproduce / 复现步骤"
      placeholder: |
        1. ...
        2. ...
        3. ...
    validations:
      required: true

  - type: input
    id: os_version
    attributes:
      label: "OS Version / 设备系统版本"
      placeholder: "e.g. macOS 14.2"
    validations:
      required: true

  - type: input
    id: app_version
    attributes:
      label: "App Version / 软件版本"
      placeholder: "e.g. v1.3.0"
    validations:
      required: true

  - type: checkboxes
    id: external_storage_type
    attributes:
      label: "External Storage Type / 外置存储设备类型"
      description: "Select all that apply / 可多选"
      options:
        - label: "NAS"
        - label: "Portable External Drive / 移动硬盘"
        - label: "Drive Enclosure / 移动硬盘盒"
        - label: "Other / 其他"
    validations:
      required: true

  - type: input
    id: external_storage_model
    attributes:
      label: "External Storage Product Name / 外置存储设备产品名"
      description: |
        If using a drive enclosure, please provide BOTH:
        - Enclosure model
        - Installed drive model

        如果使用移动硬盘盒，请填写【硬盘盒型号 + 内置硬盘型号】
      placeholder: "e.g. ORICO M.2 Enclosure + Samsung 970 EVO Plus"
    validations:
      required: false

  - type: textarea
    id: screenshots
    attributes:
      label: "Screenshots (Optional) / 截图（可选）"
      placeholder: "Drag & drop images here / 可直接拖拽截图"
    validations:
      required: false

  - type: textarea
    id: logs
    attributes:
      label: "Logs (Optional) / 日志（可选）"
      render: shell
      placeholder: "Paste logs here / 粘贴相关日志"
    validations:
      required: false
