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

export type SectionKind =
  | "prose"
  | "table"
  | "rules"
  | "checklist"
  | "ordered-steps"
  | "architecture"
  | "data-model"
  | "requirements"
  | "notes"

export type StoryRisk = "low" | "medium" | "high" | "critical"

export type WorkflowKind =
  | "ordered-steps"
  | "checklist"
  | "validation"
  | "smoke-test"
  | "migration"

export interface Plan {
  schemaVersion: PositiveInteger
  id: Slug
  title: NonEmptyString
  project?: NonEmptyString
  generatedAt?: string
  scope?: NonEmptyString
  status?: PlanStatus
  summary?: NonEmptyString[]
  metadata?: Record<string, JsonValue>
  sections?: PlanSection[]
  epics?: Epic[]
  workflows?: Workflow[]
  commands?: PlanCommand[]
  blockers?: Blocker[]
  exitCriteria?: NonEmptyString[]
  recommendedOrder?: RecommendedOrderItem[]
  changedFiles: FileTree[]
}

export interface PlanSection {
  id: Slug
  title: NonEmptyString
  kind: SectionKind
  summary?: NonEmptyString[]
  items?: SectionItem[]
  rows?: Array<Record<string, JsonValue>>
  columns?: NonEmptyString[]
}

export interface SectionItem {
  text: NonEmptyString
  title?: NonEmptyString
  status?: PlanStatus
  priority?: PositiveInteger
  tags?: NonEmptyString[]
  ref?: Slug
}

export interface Epic {
  id: Slug
  title: NonEmptyString
  stories: Story[]
  summary?: NonEmptyString
  description?: NonEmptyString
  tags?: NonEmptyString[]
  testFocus?: NonEmptyString
  status?: PlanStatus
  dependencies?: Slug[]
}

export interface Story {
  id: Slug
  title: NonEmptyString
  description?: NonEmptyString
  details?: NonEmptyString[]
  acceptanceCriteria?: NonEmptyString[]
  unitTests?: NonEmptyString[]
  dependencies?: Slug[]
  status?: PlanStatus
  tags?: NonEmptyString[]
  priority?: PositiveInteger
  risk?: StoryRisk
  owner?: string | null
  estimate?: string | number | null
  filesLikelyTouched?: NonEmptyString[]
  commandsToRun?: NonEmptyString[]
  artifacts?: NonEmptyString[]
  notes?: NonEmptyString[]
}

export interface Workflow {
  id: Slug
  title: NonEmptyString
  kind: WorkflowKind
  steps: Array<NonEmptyString | WorkflowStep>
}

export interface WorkflowStep {
  text: NonEmptyString
  id?: Slug
  command?: NonEmptyString
  expectedResults?: NonEmptyString[]
  status?: PlanStatus
  refs?: Slug[]
}

export interface PlanCommand {
  title: NonEmptyString
  command: NonEmptyString
  workingDirectory?: NonEmptyString
  environment?: Record<string, string>
  expectedResults?: NonEmptyString[]
  refs?: Slug[]
}

export interface Blocker {
  priority: PositiveInteger
  area: NonEmptyString
  requiredFix: NonEmptyString
  status?: PlanStatus
  refs?: Slug[]
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
