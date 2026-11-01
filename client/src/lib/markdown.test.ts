import { describe, it, expect } from "vitest"
import {
  escapeHtml,
  formatLanguage,
  highlightTokens,
  renderMarkdown,
} from "./markdown"

describe("markdown utilities", () => {
  it("escapes html characters properly", () => {
    expect(escapeHtml('<div class="test">&\'</div>')).toBe(
      "&lt;div class=&quot;test&quot;&gt;&amp;&#39;&lt;/div&gt;",
    )
  })

  it("formats languages predictably", () => {
    expect(formatLanguage(null)).toBe("Plain text")
    expect(formatLanguage("")).toBe("Plain text")
    expect(formatLanguage("goose")).toBe("Goose")
    expect(formatLanguage("sh")).toBe("Shell")
    expect(formatLanguage("bash")).toBe("Shell")
    expect(formatLanguage("js")).toBe("JavaScript")
    expect(formatLanguage("typescript")).toBe("TypeScript")
    expect(formatLanguage("json")).toBe("JSON")
    expect(formatLanguage("python")).toBe("Python")
  })

  it("tokenizes comments, strings, numbers, and keywords", () => {
    const code = '// comment\nfn test() {\n  let x = "hello";\n  return 42;\n}'
    const highlighted = highlightTokens(code)
    expect(highlighted).toContain('<span class="tok-comment">// comment</span>')
    expect(highlighted).toContain('<span class="tok-keyword">fn</span>')
    expect(highlighted).toContain('<span class="tok-keyword">let</span>')
    expect(highlighted).toContain('<span class="tok-string">&quot;hello&quot;</span>')
    expect(highlighted).toContain('<span class="tok-keyword">return</span>')
    expect(highlighted).toContain('<span class="tok-number">42</span>')
  })

  it("transforms local path markdown links into copy-path buttons", () => {
    const input = "[Source File](/Users/bob/project/file.goose)"
    const html = renderMarkdown(input)
    expect(html).toContain(
      '<button type="button" class="copy-path" data-copy-path="/Users/bob/project/file.goose" title="/Users/bob/project/file.goose">Source File</button>',
    )
  })

  it("handles relative local paths (./, ../, ~)", () => {
    const dotSlash = renderMarkdown("[Local](./src/foo.ts)")
    expect(dotSlash).toContain('data-copy-path="./src/foo.ts"')

    const dotDot = renderMarkdown("[Parent](../docs/readme.md)")
    expect(dotDot).toContain('data-copy-path="../docs/readme.md"')

    const tilde = renderMarkdown("[Home](~/scripts/agent.sh)")
    expect(tilde).toContain('data-copy-path="~/scripts/agent.sh"')
  })

  it("preserves external web links and anchor links", () => {
    const web = renderMarkdown("[Site](https://example.com)")
    expect(web).toContain('<a href="https://example.com">Site</a>')

    const anchor = renderMarkdown("[API Guide](#reference-unit-api)")
    expect(anchor).toContain('<a href="#reference-unit-api">API Guide</a>')
  })

  it("wraps fenced code blocks in code-example with toolbar and copy button", () => {
    const md = "```goose\nfn run() {}\n```"
    const html = renderMarkdown(md)
    expect(html).toContain('<div class="code-example">')
    expect(html).toContain('<div class="code-toolbar">')
    expect(html).toContain('<span class="code-language">Goose</span>')
    expect(html).toContain(
      '<button class="copy-code" type="button" data-copy-code aria-label="Copy code example">Copy</button>',
    )
    expect(html).toContain('<pre><code class="language-goose">')
    expect(html).toContain('<span class="tok-keyword">fn</span> run() {}')
  })

  it("wraps tables in table-scroll wrapper", () => {
    const tableMd = "| Header 1 | Header 2 |\n| --- | --- |\n| Cell 1 | Cell 2 |"
    const html = renderMarkdown(tableMd)
    expect(html).toContain(
      '<div class="table-scroll" tabindex="0" aria-label="Reference table"><table>',
    )
  })
})
