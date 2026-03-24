define("vs/basic-languages/shell/shell", [], function () {
  "use strict";

  return {
    conf: {
      comments: { lineComment: "#" },
      brackets: [["{", "}"], ["[", "]"], ["(", ")"]],
      autoClosingPairs: [
        { open: "{", close: "}" },
        { open: "[", close: "]" },
        { open: "(", close: ")" },
        { open: '"', close: '"' },
        { open: "'", close: "'" }
      ],
      surroundingPairs: [
        { open: "{", close: "}" },
        { open: "[", close: "]" },
        { open: "(", close: ")" },
        { open: '"', close: '"' },
        { open: "'", close: "'" }
      ]
    },
    language: {
      defaultToken: "",
      tokenPostfix: ".sh",
      keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "select", "in", "time", "coproc"],
      tokenizer: {
        root: [
          [/#.*$/, "comment"],
          [/"([^"\\]|\\.)*"/, "string"],
          [/'([^'\\]|\\.)*'/, "string"],
          [/\b(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|function|select|in|time|coproc)\b/, "keyword"],
          [/[{}()\[\]]/, "@brackets"],
          [/\$\{?[a-zA-Z_][\w-]*\}?/, "variable"],
          [/[a-zA-Z_][\w-]*/, "identifier"],
          [/\s+/, ""]
        ]
      }
    }
  };
});