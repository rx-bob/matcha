import { describe, it, expect } from "vitest"
import type { FileTree } from "../../../src/plan"
import { countFileStats, computeChildPath } from "./fileTreeHelpers"

describe("fileTreeHelpers", () => {
  const sampleTrees: FileTree[] = [
    {
      root: {
        name: "project",
        type: "folder",
        children: [
          {
            name: "src",
            type: "folder",
            children: [
              {
                name: "main.ts",
                type: "file",
                status: "new",
              },
              {
                name: "utils.ts",
                type: "file",
                status: "modified",
              },
            ],
          },
          {
            name: "README.md",
            type: "file",
            status: "new",
          },
        ],
      },
    },
  ]

  it("calculates total, new, and modified file counts accurately", () => {
    const stats = countFileStats(sampleTrees)
    expect(stats).toEqual({
      total: 3,
      newCount: 2,
      modCount: 1,
    })
  })

  it("computes nested child path from parent path and child name", () => {
    expect(computeChildPath("", "root")).toBe("root")
    expect(computeChildPath("root", "src")).toBe("root/src")
    expect(computeChildPath("root/src", "main.ts")).toBe("root/src/main.ts")
    expect(computeChildPath("root/src", "main.ts", "custom/explicit.ts")).toBe(
      "custom/explicit.ts",
    )
  })
})
