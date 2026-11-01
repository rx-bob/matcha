import type { FileTree, FileTreeNode } from "../../../src/plan"

export interface FileStats {
  total: number
  newCount: number
  modCount: number
}

export function countFileStats(trees: FileTree[]): FileStats {
  let total = 0
  let newCount = 0
  let modCount = 0

  function traverse(node: FileTreeNode) {
    if (node.type === "file") {
      total++
      if (node.status === "new") newCount++
      else if (node.status === "modified") modCount++
      return
    }
    for (const child of node.children ?? []) {
      traverse(child)
    }
  }

  for (const tree of trees ?? []) {
    if (tree.root) {
      traverse(tree.root)
    }
  }

  return { total, newCount, modCount }
}

export function computeChildPath(
  parentPath: string,
  childName: string,
  explicitPath?: string,
): string {
  if (explicitPath) return explicitPath
  if (!parentPath) return childName
  return `${parentPath}/${childName}`
}
