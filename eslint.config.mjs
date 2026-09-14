import js from "@eslint/js";
import globals from "globals";

export default [
  {
    files: ["site/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      globals: globals.browser,
      sourceType: "script",
    },
    rules: {
      ...js.configs.recommended.rules,
      complexity: ["error", 9],
      "max-lines": ["error", { max: 400, skipBlankLines: false, skipComments: false }],
      "max-lines-per-function": [
        "error",
        { max: 60, skipBlankLines: false, skipComments: false, IIFEs: true },
      ],
    },
  },
];
