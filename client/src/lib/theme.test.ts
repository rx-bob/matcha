import { describe, it, expect, beforeEach } from "vitest"
import {
  defaultPlanDesign,
  defaultEvaTheme,
  planDesignStorageKey,
  evaThemeStorageKey,
  isPlanDesign,
  isEvaTheme,
  readStoredPlanDesign,
  writeStoredPlanDesign,
  readStoredEvaTheme,
  writeStoredEvaTheme,
  getFaviconUrl,
  updateFavicon,
  applyPlanDesign,
  applyEvaTheme,
  themes,
  defaultTheme,
  readStoredTheme,
  isThemeId,
} from "./theme"

describe("theme and design system", () => {
  let mockStorage: Record<string, string>
  let mockDataset: Record<string, string>
  let mockIconLink: { rel: string; href: string } | null

  beforeEach(() => {
    mockStorage = {}
    mockDataset = {}
    mockIconLink = null

    // Mock localStorage
    const storage = {
      getItem: (key: string) => (key in mockStorage ? mockStorage[key] : null),
      setItem: (key: string, value: string) => {
        mockStorage[key] = String(value)
      },
      removeItem: (key: string) => {
        delete mockStorage[key]
      },
      clear: () => {
        mockStorage = {}
      },
    }

    // @ts-expect-error global mock
    globalThis.localStorage = storage

    // Mock document
    const docElement = {
      dataset: mockDataset,
      setAttribute: (key: string, value: string) => {
        mockDataset[key.replace("data-", "")] = value
      },
      removeAttribute: (key: string) => {
        delete mockDataset[key.replace("data-", "")]
      },
    }

    // @ts-expect-error Partial DOM fixture for theme state tests.
    globalThis.document = {
      documentElement: docElement as unknown as HTMLElement,
      querySelector: (selector: string) => {
        if (selector === 'link[rel="icon"]') {
          return mockIconLink
        }
        return null
      },
    }
  })

  it("uses explicit sample design overrides instead of saved preferences", () => {
    mockStorage[planDesignStorageKey] = "coral"
    mockStorage[evaThemeStorageKey] = "dark"
    mockDataset.initialDesign = "eva-01"
    mockDataset.initialEvaTheme = "light"
    mockDataset.evaThemeStorageKey = "matcha-eva-theme:preview-light"
    expect(readStoredPlanDesign()).toBe("eva-01")
    expect(readStoredEvaTheme()).toBe("light")
    expect(mockStorage[planDesignStorageKey]).toBe("coral")
    expect(mockStorage[evaThemeStorageKey]).toBe("dark")
  })

  it("remembers color changes in each preview without overwriting another preview's default", () => {
    mockDataset.initialEvaTheme = "dark"
    mockDataset.evaThemeStorageKey = "matcha-eva-theme:preview-dark"
    expect(readStoredEvaTheme()).toBe("dark")
    applyEvaTheme("light")
    expect(readStoredEvaTheme()).toBe("light")
    mockDataset.initialEvaTheme = "light"
    mockDataset.evaThemeStorageKey = "matcha-eva-theme:preview-light"
    expect(readStoredEvaTheme()).toBe("light")
    applyEvaTheme("dark")
    expect(readStoredEvaTheme()).toBe("dark")
    mockDataset.evaThemeStorageKey = "matcha-eva-theme:preview-dark"
    expect(readStoredEvaTheme()).toBe("light")
  })

  describe("defaults and guards", () => {
    it("has expected defaults and storage keys", () => {
      expect(defaultPlanDesign).toBe("coral")
      expect(defaultEvaTheme).toBe("dark")
      expect(planDesignStorageKey).toBe("matcha-plan-design")
      expect(evaThemeStorageKey).toBe("matcha-eva-theme")
    })

    it("validates plan designs", () => {
      expect(isPlanDesign("coral")).toBe(true)
      expect(isPlanDesign("chonk")).toBe(true)
      expect(isPlanDesign("eva-01")).toBe(true)
      expect(isPlanDesign("unknown")).toBe(false)
      expect(isPlanDesign(null)).toBe(false)
      expect(isPlanDesign(undefined)).toBe(false)
    })

    it("validates eva themes", () => {
      expect(isEvaTheme("dark")).toBe(true)
      expect(isEvaTheme("light")).toBe(true)
      expect(isEvaTheme("blue")).toBe(false)
      expect(isEvaTheme(null)).toBe(false)
      expect(isEvaTheme(undefined)).toBe(false)
    })
  })

  describe("storage persistence", () => {
    it("reads stored plan design with fallback to coral", () => {
      expect(readStoredPlanDesign()).toBe("coral")
      writeStoredPlanDesign("chonk")
      expect(readStoredPlanDesign()).toBe("chonk")
      localStorage.setItem(planDesignStorageKey, "invalid")
      expect(readStoredPlanDesign()).toBe("coral")
    })

    it("reads stored eva theme with fallback to dark", () => {
      expect(readStoredEvaTheme()).toBe("dark")
      writeStoredEvaTheme("light")
      expect(readStoredEvaTheme()).toBe("light")
      localStorage.setItem(evaThemeStorageKey, "invalid")
      expect(readStoredEvaTheme()).toBe("dark")
    })
  })

  describe("favicon generation", () => {
    it("embeds a distinct mascot PNG for each design", () => {
      const icons = ["coral", "chonk", "eva-01"].map(design => getFaviconUrl(design as "coral" | "chonk" | "eva-01"))
      expect(new Set(icons).size).toBe(3)
      for (const icon of icons) expect(icon).toMatch(/^data:image\/png;base64,iVBOR/)
    })

    it("updates the favicon when the selected design changes", () => {
      mockIconLink = { rel: "icon", href: "" }
      for (const design of ["coral", "chonk", "eva-01"] as const) {
        updateFavicon(design)
        expect(mockIconLink.href).toBe(getFaviconUrl(design))
      }
    })
  })

  describe("applyPlanDesign and applyEvaTheme transitions", () => {
    it("applies coral design forcing light theme", () => {
      const result = applyPlanDesign("coral", "dark")
      expect(result.design).toBe("coral")
      expect(result.theme).toBe("light")
      expect(mockDataset.design).toBe("coral")
      expect(mockDataset.theme).toBe("light")
      expect(localStorage.getItem(planDesignStorageKey)).toBe("coral")
    })

    it("applies chonk design forcing dark theme", () => {
      const result = applyPlanDesign("chonk", "light")
      expect(result.design).toBe("chonk")
      expect(result.theme).toBe("dark")
      expect(mockDataset.design).toBe("chonk")
      expect(mockDataset.theme).toBe("dark")
      expect(localStorage.getItem(planDesignStorageKey)).toBe("chonk")
    })

    it("applies eva-01 with specified evaTheme", () => {
      const darkResult = applyPlanDesign("eva-01", "dark")
      expect(darkResult.design).toBe("eva-01")
      expect(darkResult.theme).toBe("dark")
      expect(mockDataset.design).toBe("eva-01")
      expect(mockDataset.theme).toBe("dark")

      const lightResult = applyPlanDesign("eva-01", "light")
      expect(lightResult.design).toBe("eva-01")
      expect(lightResult.theme).toBe("light")
      expect(mockDataset.design).toBe("eva-01")
      expect(mockDataset.theme).toBe("light")
    })

    it("falls back to default design on unknown input", () => {
      // @ts-expect-error testing invalid input
      const result = applyPlanDesign("nonexistent")
      expect(result.design).toBe("coral")
      expect(result.theme).toBe("light")
    })

    it("toggles evaTheme via applyEvaTheme when eva-01 is active", () => {
      applyPlanDesign("eva-01", "dark")
      expect(mockDataset.theme).toBe("dark")

      applyEvaTheme("light")
      expect(mockDataset.theme).toBe("light")
      expect(localStorage.getItem(evaThemeStorageKey)).toBe("light")

      applyEvaTheme("dark")
      expect(mockDataset.theme).toBe("dark")
      expect(localStorage.getItem(evaThemeStorageKey)).toBe("dark")
    })

    it("does not overwrite document theme if active design is not eva-01", () => {
      applyPlanDesign("coral")
      expect(mockDataset.theme).toBe("light")

      applyEvaTheme("dark")
      // coral remains light, but storage is updated
      expect(mockDataset.theme).toBe("light")
      expect(localStorage.getItem(evaThemeStorageKey)).toBe("dark")
    })
  })

  describe("map backward compatibility", () => {
    it("preserves 18 flat themes and legacy functions", () => {
      expect(themes.length).toBe(18)
      expect(defaultTheme).toBe("catppuccin-latte")
      expect(isThemeId("catppuccin-latte")).toBe(true)
      expect(isThemeId("non-existent")).toBe(false)
      expect(readStoredTheme("map-theme")).toBe("catppuccin-latte")
    })
  })
})
