export const planDesignStorageKey = "matcha-plan-design"
export const evaThemeStorageKey = "matcha-eva-theme"

export type PlanDesign = "coral" | "mistral" | "eva-01"
export type EvaTheme = "dark" | "light"

export const defaultPlanDesign: PlanDesign = "coral"
export const defaultEvaTheme: EvaTheme = "dark"

export const planDesigns: readonly PlanDesign[] = ["mistral", "coral", "eva-01"] as const

export function isPlanDesign(value: string | null | undefined): value is PlanDesign {
  return value === "coral" || value === "mistral" || value === "eva-01"
}

export function isEvaTheme(value: string | null | undefined): value is EvaTheme {
  return value === "dark" || value === "light"
}

export function readStoredPlanDesign(storageKey = planDesignStorageKey): PlanDesign {
  try {
    if (typeof localStorage !== "undefined") {
      const saved = localStorage.getItem(storageKey)
      if (isPlanDesign(saved)) {
        return saved
      }
    }
  } catch {}
  return defaultPlanDesign
}

export function writeStoredPlanDesign(design: PlanDesign, storageKey = planDesignStorageKey): void {
  try {
    if (typeof localStorage !== "undefined") {
      localStorage.setItem(storageKey, design)
    }
  } catch {}
}

export function readStoredEvaTheme(storageKey = evaThemeStorageKey): EvaTheme {
  try {
    if (typeof localStorage !== "undefined") {
      const saved = localStorage.getItem(storageKey)
      if (isEvaTheme(saved)) {
        return saved
      }
    }
  } catch {}
  return defaultEvaTheme
}

export function writeStoredEvaTheme(theme: EvaTheme, storageKey = evaThemeStorageKey): void {
  try {
    if (typeof localStorage !== "undefined") {
      localStorage.setItem(storageKey, theme)
    }
  } catch {}
}

export function getFaviconSvg(design: PlanDesign): string {
  const coral = design === "coral"
  const mistral = design === "mistral"
  const rx = coral ? 10 : mistral ? 4 : 0
  const bg = coral ? "#f5f3ef" : mistral ? "#0b0b12" : "#0d0d13"
  const fill = coral ? "#ff806e" : mistral ? "#ff8200" : "#bdff39"
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" rx="${rx}" fill="${bg}"/><path d="M10 28c0-5 8-4 10-9V11c0-6 9-6 9 0h5l-6 4v9c0 6-12 10-18 4Z" fill="${fill}"/></svg>`
}

export function updateFavicon(design: PlanDesign): void {
  if (typeof document === "undefined") return
  const iconLink = document.querySelector('link[rel="icon"]') as HTMLLinkElement | null
  if (iconLink) {
    iconLink.href = "data:image/svg+xml," + encodeURIComponent(getFaviconSvg(design))
  }
}

export function applyPlanDesign(
  design: PlanDesign,
  evaTheme: EvaTheme = defaultEvaTheme,
  persist = true
): { design: PlanDesign; theme: "dark" | "light" } {
  const validDesign: PlanDesign = isPlanDesign(design) ? design : defaultPlanDesign
  const validEvaTheme: EvaTheme = isEvaTheme(evaTheme) ? evaTheme : defaultEvaTheme

  const theme: "dark" | "light" =
    validDesign === "coral"
      ? "light"
      : validDesign === "mistral"
        ? "dark"
        : validEvaTheme

  if (typeof document !== "undefined") {
    document.documentElement.dataset.design = validDesign
    document.documentElement.dataset.theme = theme
    updateFavicon(validDesign)
  }

  if (persist) {
    writeStoredPlanDesign(validDesign)
  }

  return { design: validDesign, theme }
}

export function applyEvaTheme(theme: EvaTheme, persist = true): EvaTheme {
  const validTheme: EvaTheme = isEvaTheme(theme) ? theme : defaultEvaTheme

  if (typeof document !== "undefined") {
    if (document.documentElement.dataset.design === "eva-01") {
      document.documentElement.dataset.theme = validTheme
    }
  }

  if (persist) {
    writeStoredEvaTheme(validTheme)
  }

  return validTheme
}

// ---------------------------------------------------------------------------
// Legacy Matcha Map / 18 Flat Themes Compatibility
// ---------------------------------------------------------------------------
export const defaultTheme = "catppuccin-latte"
export const planThemeStorageKey = "matcha-plan-theme"
export const mapThemeStorageKey = "matcha-map-theme"

export const themes = [
  { id: "catppuccin-latte", label: "Catppuccin Latte" },
  { id: "catppuccin", label: "Catppuccin" },
  { id: "dracula", label: "Dracula" },
  { id: "gruvbox", label: "Gruvbox" },
  { id: "gruvbox-light", label: "Gruvbox Light" },
  { id: "kanagawa", label: "Kanagawa" },
  { id: "kanagawa-lotus", label: "Kanagawa Lotus" },
  { id: "nord", label: "Nord" },
  { id: "one-dark", label: "One Dark" },
  { id: "one-light", label: "One Light" },
  { id: "rose-pine", label: "Rose Pine" },
  { id: "rose-pine-dawn", label: "Rose Pine Dawn" },
  { id: "solarized", label: "Solarized" },
  { id: "solarized-light", label: "Solarized Light" },
  { id: "terminal", label: "Terminal" },
  { id: "tokyo-night", label: "Tokyo Night" },
  { id: "tokyo-night-day", label: "Tokyo Night Day" },
  { id: "vesper", label: "Vesper" },
] as const

export type ThemeId = (typeof themes)[number]["id"]

export function isThemeId(value: string | null): value is ThemeId {
  return themes.some((theme) => theme.id === value)
}

export function readStoredTheme(storageKey: string): ThemeId {
  try {
    if (typeof localStorage !== "undefined") {
      const saved = localStorage.getItem(storageKey)
      if (isThemeId(saved)) {
        return saved
      }
    }
  } catch {}

  return defaultTheme
}

export function writeStoredTheme(storageKey: string, theme: ThemeId): void {
  try {
    if (typeof localStorage !== "undefined") {
      localStorage.setItem(storageKey, theme)
    }
  } catch {}
}

export function applyTheme(theme: ThemeId): void {
  if (typeof document !== "undefined") {
    document.documentElement.setAttribute("data-theme", theme)
  }
}
