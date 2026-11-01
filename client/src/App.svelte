<script lang="ts">
  import { onMount } from "svelte"
  import type { Plan } from "../../src/plan.ts"
  import SvgSprite from "./components/ui/SvgSprite.svelte"
  import PlanPage from "./components/sections/PlanPage.svelte"
  import {
    type PlanDesign,
    type EvaTheme,
    readStoredPlanDesign,
    readStoredEvaTheme,
    applyPlanDesign,
    applyEvaTheme,
  } from "./lib/theme"
  import { resolveViewForHash } from "./lib/overviewHelpers"

  export let plan: Plan

  let currentDesign: PlanDesign = "coral"
  let currentEvaTheme: EvaTheme = "dark"
  let currentView = "overview"
  let isNavOpen = false
  let isExportOpen = false
  let isMobile = false
  let searchShortcut = "⌘ K"

  let sidebarElement: HTMLElement | null = null

  const viewTitles: Record<string, string> = {
    overview: "Overview",
    epics: "Implementation",
    files: "Project files",
    context: "Architecture & decisions",
    order: "Delivery order",
    criteria: "Release criteria",
  }

  $: projectName = plan.project || plan.id || "matcha"
  $: currentViewTitle = viewTitles[currentView] || "Overview"

  function selectDesign(design: PlanDesign): void {
    currentDesign = design
    const result = applyPlanDesign(design, currentEvaTheme)
    currentEvaTheme = result.theme === "dark" || result.theme === "light" ? result.theme : currentEvaTheme
  }

  function selectEvaTheme(theme: EvaTheme): void {
    currentEvaTheme = theme
    applyEvaTheme(theme)
  }

  function setNavigation(open: boolean, restoreFocus = true): void {
    isNavOpen = open && isMobile
    if (typeof document !== "undefined") {
      document.body.classList.toggle("nav-open", isNavOpen)
      document.body.style.overflow = isNavOpen ? "hidden" : ""
      if (sidebarElement) {
        sidebarElement.inert = isMobile && !isNavOpen
      }
      if (isNavOpen) {
        const activeLink = sidebarElement?.querySelector<HTMLElement>(".nav-link.is-active")
        activeLink?.focus()
      } else if (restoreFocus && isMobile) {
        const menuBtn = document.getElementById("mobile-menu")
        menuBtn?.focus()
      }
    }
  }

  function toggleNav(): void {
    setNavigation(!isNavOpen)
  }

  function selectView(view: string): void {
    currentView = view
    if (isNavOpen) {
      setNavigation(false, false)
    }
    if (typeof window !== "undefined") {
      if (window.location.hash !== `#${view}`) {
        window.history.pushState(null, "", `#${view}`)
      }
      document.title = `${viewTitles[view] || "Overview"} · ${projectName}`
    }
  }

  function toggleExport(): void {
    isExportOpen = !isExportOpen
  }

  function closeExport(): void {
    isExportOpen = false
  }

  function handleSearchClick(): void {
    closeExport()
    const searchDialog = document.getElementById("search-dialog") as HTMLDialogElement | null
    if (searchDialog && !searchDialog.open) {
      searchDialog.showModal()
    }
  }

  function exportPlan(type: "html" | "json" | "print"): void {
    closeExport()
    const filenameBase = projectName.toLowerCase().replace(/[^a-z0-9_-]/g, "-")

    if (type === "json") {
      download(`${filenameBase}-plan.json`, JSON.stringify(plan, null, 2), "application/json")
    } else if (type === "html") {
      const clone = document.documentElement.cloneNode(true) as HTMLElement
      const cloneBody = clone.querySelector("body")
      if (cloneBody) {
        cloneBody.classList.remove("nav-open")
        cloneBody.style.overflow = ""
      }
      clone.querySelector("#sidebar")?.removeAttribute("inert")
      const overlay = clone.querySelector(".nav-overlay") as HTMLElement | null
      if (overlay) overlay.hidden = true
      download(`${filenameBase}-plan.html`, "<!DOCTYPE html>\n" + clone.outerHTML, "text/html;charset=utf-8")
    } else if (type === "print") {
      window.print()
    }
  }

  function download(name: string, content: string, mimeType: string): void {
    const blob = new Blob([content], { type: mimeType })
    const url = URL.createObjectURL(blob)
    const link = document.createElement("a")
    link.href = url
    link.download = name
    document.body.appendChild(link)
    link.click()
    link.remove()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }

  function onSidebarKeydown(event: KeyboardEvent): void {
    if (!isMobile || !isNavOpen || event.key !== "Tab" || !sidebarElement) return

    const focusable = Array.from(
      sidebarElement.querySelectorAll<HTMLElement>("a, button, [tabindex]:not([tabindex='-1'])")
    ).filter((el) => el.offsetParent !== null || el.getClientRects().length > 0)

    if (focusable.length === 0) return

    const first = focusable[0]
    const last = focusable[focusable.length - 1]

    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  function onWindowKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      if (isNavOpen) {
        event.preventDefault()
        setNavigation(false, true)
      }
      if (isExportOpen) {
        closeExport()
      }
    }

    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      const searchTrigger = document.getElementById("open-search")
      if (searchTrigger) {
        event.preventDefault()
        searchTrigger.click()
      }
    }
  }

  function onDocumentClick(event: MouseEvent): void {
    const target = event.target as HTMLElement | null
    if (isExportOpen && target && !target.closest(".export-wrap")) {
      closeExport()
    }

    const link = target?.closest<HTMLAnchorElement>('a[href^="#"]')
    if (link && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey) {
      const href = link.getAttribute("href")
      if (href && href !== "#main-content") {
        const resolved = resolveViewForHash(href, plan)
        if (resolved && resolved !== currentView) {
          currentView = resolved
          document.title = `${viewTitles[resolved] || "Overview"} · ${projectName}`
        }
      }
    }
  }

  onMount(() => {
    currentDesign = readStoredPlanDesign()
    currentEvaTheme = readStoredEvaTheme()
    applyPlanDesign(currentDesign, currentEvaTheme, false)

    if (typeof navigator !== "undefined" && !/Mac|iPhone|iPad/.test(navigator.platform)) {
      searchShortcut = "Ctrl K"
    }

    const media = window.matchMedia("(max-width: 760px)")
    isMobile = media.matches
    const onMediaChange = (e: MediaQueryListEvent) => {
      isMobile = e.matches
      if (!isMobile && isNavOpen) {
        setNavigation(false, false)
      } else if (sidebarElement) {
        sidebarElement.inert = isMobile && !isNavOpen
      }
    }
    media.addEventListener("change", onMediaChange)

    const syncHash = () => {
      const targetView = resolveViewForHash(window.location.hash, plan)
      currentView = targetView
      document.title = `${viewTitles[targetView] || "Overview"} · ${projectName}`
    }
    window.addEventListener("hashchange", syncHash)
    syncHash()

    window.addEventListener("keydown", onWindowKeydown)
    document.addEventListener("click", onDocumentClick)

    if (sidebarElement) {
      sidebarElement.inert = isMobile && !isNavOpen
    }

    return () => {
      media.removeEventListener("change", onMediaChange)
      window.removeEventListener("hashchange", syncHash)
      window.removeEventListener("keydown", onWindowKeydown)
      document.removeEventListener("click", onDocumentClick)
      if (typeof document !== "undefined") {
        document.body.classList.remove("nav-open")
        document.body.style.overflow = ""
      }
    }
  })
</script>

<a href="#main-content" class="skip-link">Skip to content</a>

<SvgSprite />

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<aside
  class="sidebar"
  id="sidebar"
  aria-label="Project navigation"
  bind:this={sidebarElement}
  on:keydown={onSidebarKeydown}
>
  <button class="sidebar-close" aria-label="Close navigation" data-close-nav on:click={() => setNavigation(false)}>
    <svg><use href="#i-close" /></svg>
  </button>

  <a href="#overview" class="brand" aria-label="{projectName} overview" on:click={() => selectView("overview")}>
    <span class="brandmark">
      <svg viewBox="0 0 34 38" aria-hidden="true">
        <path d="M6 28c0-4 5-4 9-8 2-2 2-5 2-8V9c0-7 10-7 10 0l5 2-6 3v10c0 7-13 10-20 4Z" />
        <path d="M9 25c2 2 6 1 8-1M14 32l-1 4m7-5 1 5M24 8h.1" />
      </svg>
    </span>
    <span class="brand-type">{projectName}</span>
  </a>

  <nav aria-label="Plan sections">
    <a
      href="#overview"
      class="nav-link {currentView === 'overview' ? 'is-active' : ''}"
      data-nav="overview"
      aria-current={currentView === "overview" ? "page" : undefined}
      on:click={() => selectView("overview")}
    >
      <svg aria-hidden="true"><use href="#i-grid" /></svg>
      <span>Overview</span>
    </a>
    <a
      href="#epics"
      class="nav-link {currentView === 'epics' ? 'is-active' : ''}"
      data-nav="epics"
      aria-current={currentView === "epics" ? "page" : undefined}
      on:click={() => selectView("epics")}
    >
      <svg aria-hidden="true"><use href="#i-layers" /></svg>
      <span>Implementation</span>
    </a>
    <a
      href="#files"
      class="nav-link {currentView === 'files' ? 'is-active' : ''}"
      data-nav="files"
      aria-current={currentView === "files" ? "page" : undefined}
      on:click={() => selectView("files")}
    >
      <svg aria-hidden="true"><use href="#i-folder" /></svg>
      <span>Project files</span>
    </a>
    <div class="nav-divider" aria-hidden="true"></div>
    <a
      href="#context"
      class="nav-link {currentView === 'context' ? 'is-active' : ''}"
      data-nav="context"
      aria-current={currentView === "context" ? "page" : undefined}
      on:click={() => selectView("context")}
    >
      <svg aria-hidden="true"><use href="#i-book" /></svg>
      <span>Architecture & decisions</span>
    </a>
    <a
      href="#order"
      class="nav-link {currentView === 'order' ? 'is-active' : ''}"
      data-nav="order"
      aria-current={currentView === "order" ? "page" : undefined}
      on:click={() => selectView("order")}
    >
      <svg aria-hidden="true"><use href="#i-order" /></svg>
      <span>Delivery order</span>
    </a>
    <a
      href="#criteria"
      class="nav-link {currentView === 'criteria' ? 'is-active' : ''}"
      data-nav="criteria"
      aria-current={currentView === "criteria" ? "page" : undefined}
      on:click={() => selectView("criteria")}
    >
      <svg aria-hidden="true"><use href="#i-check" /></svg>
      <span>Release criteria</span>
    </a>
  </nav>

  <div class="sidebar-foot">
    <div class="design-switch" role="group" aria-label="Design theme">
      <button
        data-design-choice="mistral"
        aria-pressed={currentDesign === "mistral"}
        on:click={() => selectDesign("mistral")}
      >
        Mistral
      </button>
      <button
        data-design-choice="coral"
        aria-pressed={currentDesign === "coral"}
        on:click={() => selectDesign("coral")}
      >
        Coral
      </button>
      <button
        data-design-choice="eva-01"
        aria-pressed={currentDesign === "eva-01"}
        on:click={() => selectDesign("eva-01")}
      >
        Eva
      </button>
    </div>

    <div
      class="theme-switch"
      data-eva-only
      role="group"
      aria-label="Eva color mode"
      hidden={currentDesign !== "eva-01"}
    >
      <button
        data-theme-choice="dark"
        aria-pressed={currentEvaTheme === "dark"}
        on:click={() => selectEvaTheme("dark")}
      >
        <svg aria-hidden="true"><use href="#i-moon" /></svg>Dark
      </button>
      <button
        data-theme-choice="light"
        aria-pressed={currentEvaTheme === "light"}
        on:click={() => selectEvaTheme("light")}
      >
        <svg aria-hidden="true"><use href="#i-sun" /></svg>Light
      </button>
    </div>
  </div>
</aside>

<button
  class="nav-overlay"
  data-close-nav
  aria-label="Close navigation"
  hidden={!isNavOpen}
  on:click={() => setNavigation(false)}
></button>

<div class="app-main">
  <header class="topbar">
    <button
      class="icon-button mobile-menu"
      id="mobile-menu"
      aria-label="Open navigation"
      aria-controls="sidebar"
      aria-expanded={isNavOpen}
      on:click={toggleNav}
    >
      <svg aria-hidden="true"><use href="#i-menu" /></svg>
    </button>

    <div class="breadcrumbs">
      <span class="project-crumb">{projectName}</span>
      <span class="slash second-slash">/</span>
      <strong id="breadcrumb-current">{currentViewTitle}</strong>
    </div>

    <div class="topbar-actions">
      <button
        class="search-trigger"
        id="open-search"
        aria-label="Search plan"
        aria-haspopup="dialog"
        on:click={handleSearchClick}
      >
        <svg aria-hidden="true"><use href="#i-search" /></svg>
        <span>Find in plan…</span>
        <kbd id="search-shortcut">{searchShortcut}</kbd>
      </button>

      <div class="export-wrap">
        <button
          class="btn export-trigger"
          id="export-trigger"
          aria-expanded={isExportOpen}
          aria-controls="export-menu"
          on:click={toggleExport}
        >
          <svg aria-hidden="true"><use href="#i-download" /></svg>
          <span>Export plan</span>
        </button>

        <div class="export-menu" id="export-menu" hidden={!isExportOpen}>
          <button data-export="html" on:click={() => exportPlan("html")}>
            <svg aria-hidden="true"><use href="#i-download" /></svg>Download HTML
          </button>
          <button data-export="json" on:click={() => exportPlan("json")}>
            <svg aria-hidden="true"><use href="#i-code" /></svg>Export plan data
          </button>
          <button data-export="print" on:click={() => exportPlan("print")}>
            <svg aria-hidden="true"><use href="#i-print" /></svg>Print / save as PDF
          </button>
        </div>
      </div>
    </div>
  </header>

  <main class="content" id="main-content" tabindex="-1">
    <PlanPage {plan} {currentView} />
  </main>
</div>
