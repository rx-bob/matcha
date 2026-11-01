export type Slug = string
export type NonEmptyString = string
export type PositiveInteger = number

export type PlanStatus =
  | "draft"
  | "planned"
  | "ready"
  | "in-progress"
  | "blocked"
  | "complete"
  | "archived"

export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue }

export type HeroTitle =
  | NonEmptyString
  | {
      lead: NonEmptyString
      accent?: NonEmptyString
    }

export type SectionKind =
  | "prose"
  | "rules"
  | "checklist"
  | "ordered-steps"
  | "architecture"
  | "data-model"
  | "requirements"
  | "notes"

export type StoryRisk = "low" | "medium" | "high" | "critical"

export interface Plan {
  schemaVersion: PositiveInteger
  id: Slug
  title: NonEmptyString
  heroTitle?: HeroTitle
  firstStorySummary?: NonEmptyString
  project?: NonEmptyString
  generatedAt?: string
  scope?: NonEmptyString
  status?: PlanStatus
  summary?: NonEmptyString[]
  metadata?: Record<string, JsonValue>
  sections?: PlanSection[]
  epics?: Epic[]
  exitCriteria?: NonEmptyString[]
  recommendedOrder?: RecommendedOrderItem[]
  changedFiles: FileTree[]
}

export interface PlanSection {
  id: Slug
  title: NonEmptyString
  kind?: SectionKind
  summary?: NonEmptyString[]
  items?: SectionItem[]
}

export interface SectionItem {
  text: NonEmptyString
  title?: NonEmptyString
}

export interface Epic {
  id: Slug
  title: NonEmptyString
  shortTitle?: NonEmptyString
  summary?: NonEmptyString
  description?: NonEmptyString
  status?: PlanStatus
  dependencies?: Slug[]
  stories: Story[]
}

export interface Story {
  id: Slug
  title: NonEmptyString
  status?: PlanStatus
  risk?: StoryRisk
  dependencies?: Slug[]
  description?: NonEmptyString
  details?: NonEmptyString[]
  acceptanceCriteria?: NonEmptyString[]
  unitTests?: NonEmptyString[]
  filesLikelyTouched?: NonEmptyString[]
}

export interface RecommendedOrderItem {
  ref: Slug
  reason?: NonEmptyString
}

export type FileTreeNodeType = "folder" | "file"

export type FileNodeStatus = "new" | "modified"

export interface FileTreeNode {
  name: NonEmptyString
  type: FileTreeNodeType
  status?: FileNodeStatus
  stories?: Slug[]
  children?: FileTreeNode[]
}

export interface FileTree {
  label?: NonEmptyString
  root: FileTreeNode
}
