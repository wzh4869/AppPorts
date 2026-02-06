name: "✨ Feature / 功能建议"
description: "Suggest a new feature or improvement / 提出新功能或改进建议"
title: "[FEAT] "
labels: ["enhancement"]
body:
  - type: textarea
    id: idea
    attributes:
      label: "Idea or Problem / 你想解决的问题或新点子"
      placeholder: |
        Describe the problem you want to solve
        or the new idea you have.

        描述你想解决的问题，或你的新功能想法
    validations:
      required: true

  - type: textarea
    id: alternatives
    attributes:
      label: "Alternatives (Optional) / 备选方案（可选）"
      placeholder: "Any alternative solutions you considered? / 你考虑过的其他方案"
    validations:
      required: false

  - type: dropdown
    id: importance
    attributes:
      label: "Importance / 你认为这个点子的需求性"
      options:
        - "Low / 低"
        - "Medium / 中"
        - "High / 高"
        - "Very High / 很高"
    validations:
      required: true
