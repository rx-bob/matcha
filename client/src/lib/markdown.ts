import { Marked } from "marked"

export function escapeHtml(text: string): string {
  return String(text).replace(/[&<>"']/g, (c) => {
    switch (c) {
      case "&":
        return "&amp;"
      case "<":
        return "&lt;"
      case ">":
        return "&gt;"
      case '"':
        return "&quot;"
      case "'":
        return "&#39;"
      default:
        return c
    }
  })
}

export function formatLanguage(lang?: string | null): string {
  if (!lang) return "Plain text"
  const l = lang.trim().toLowerCase()
  if (l === "sh" || l === "bash" || l === "shell" || l === "zsh") return "Shell"
  if (l === "js" || l === "javascript") return "JavaScript"
  if (l === "ts" || l === "typescript") return "TypeScript"
  if (l === "json") return "JSON"
  if (l === "html") return "HTML"
  if (l === "css") return "CSS"
  if (l === "goose") return "Goose"
  return l.charAt(0).toUpperCase() + l.slice(1)
}

export function highlightTokens(code: string): string {
  const pattern =
    /(\/\/[^\n]*|"(?:\\.|[^"\\])*"|\b(?:fn|let|const|namespace|import|struct|return|if|else|for|while|true|false|enum|break|continue|defer|using|package)\b|\b\d+(?:\.\d+)?\b)/g
  let html = ""
  let end = 0

  for (const match of code.matchAll(pattern)) {
    const token = match[0]
    const matchIndex = match.index ?? 0
    html += escapeHtml(code.slice(end, matchIndex))

    const type = token.startsWith("//")
      ? "comment"
      : token.startsWith('"')
        ? "string"
        : /^\d/.test(token)
          ? "number"
          : "keyword"

    html += `<span class="tok-${type}">${escapeHtml(token)}</span>`
    end = matchIndex + token.length
  }

  html += escapeHtml(code.slice(end))
  return html
}

export const markdownRenderer = new Marked({
  gfm: true,
  breaks: false,
  renderer: {
    link({ href, title, text }) {
      if (/^(\/|\.\/|\.\.\/|~)/.test(href)) {
        const titleAttr = title ? ` title="${escapeHtml(title)}"` : ` title="${escapeHtml(href)}"`
        return `<button type="button" class="copy-path" data-copy-path="${escapeHtml(href)}"${titleAttr}>${text}</button>`
      }
      return false
    },
    code({ text, lang }) {
      const codeLang = formatLanguage(lang)
      const langClass = lang ? `language-${escapeHtml(lang.trim())}` : "language-text"
      const highlighted = highlightTokens(text)
      return `<div class="code-example"><div class="code-toolbar"><span class="code-language">${codeLang}</span><button class="copy-code" type="button" data-copy-code aria-label="Copy code example">Copy</button></div><pre><code class="${langClass}">${highlighted}</code></pre></div>\n`
    },
    table(token) {
      const header = this.tablerow({
        text: token.header.map((cell) => this.tablecell(cell)).join(""),
      })
      const body = token.rows
        .map((row) =>
          this.tablerow({
            text: row.map((cell) => this.tablecell(cell)).join(""),
          }),
        )
        .join("")
      return `<div class="table-scroll" tabindex="0" aria-label="Reference table"><table><thead>${header}</thead><tbody>${body}</tbody></table></div>\n`
    },
  },
})

export function renderMarkdown(markdown: string): string {
  if (!markdown) return ""
  return markdownRenderer.parse(markdown, { async: false }) as string
}
