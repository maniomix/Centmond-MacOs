# Centmond macOS — AI Port Plan

پورت کردن سیستم هوش مصنوعی از Balance iOS به Centmond macOS.
**35 فایل AI logic + 17 فایل AI views = 52 فایل**
مدل: Gemma 4 E4B (Q6_K, 6.6GB) — مسیر: `/Users/mani/Desktop/SwiftProjects/gemma-4-E4B-it-Q6_K.gguf`

---

## Master Prompt (اینو اول هر session بده)

```
You're porting an on-device AI system from Balance (iOS) to Centmond
(macOS). The source code is at:
  - iOS AI files: /Users/mani/Desktop/SwiftProjects/balance copy/balance/AI/ (35 files, ~17K lines)
  - iOS AI views: /Users/mani/Desktop/SwiftProjects/balance copy/balance/Views/AI/ (17 files, ~7.4K lines)
  - Target app: /Users/mani/Desktop/SwiftProjects/Centmond/

CRITICAL DIFFERENCES between iOS and macOS codebases:

  iOS (Balance):                     macOS (Centmond):
  ─────────────────────────────────  ─────────────────────────────────
  Store: Codable struct              SwiftData @Model entities
  store.transactions array           modelContext.fetch(Transaction)
  store.transactions.append(tx)      modelContext.insert(tx)
  inout Store                        ModelContext
  GoalManager.shared (Supabase)      Goal @Model (local SwiftData)
  AccountManager.shared (Supabase)   Account @Model (local SwiftData)
  ObservableObject singletons        @Observable classes
  UIKit (UIImagePicker, etc.)        AppKit (NSOpenPanel, no camera)
  UIImpactFeedbackGenerator          Centmond's Haptics helper
  Cents (Int) for amounts            Decimal for amounts
  import LlamaSwift                  import LlamaSwift (same SPM)

Model upgrade:
  iOS:  Gemma 4 E2B (2B params, Q4_K_M, 3.1GB)
  macOS: Gemma 4 E4B (4B params, Q6_K, 6.6GB)
  Path: /Users/mani/Desktop/SwiftProjects/gemma-4-E4B-it-Q6_K.gguf

macOS optimal params (M4 16GB):
  n_gpu_layers = 99   // full Metal offload
  n_ctx        = 8192  // 4x iOS
  n_batch      = 512
  maxTokens    = 2048  // 4x iOS
  flash_attn   = .auto
  n_threads    = 4

Target folder structure in Centmond:
  Centmond/AI/Core/           — AIManager, AIModels, AISystemPrompt,
                                AIContextBuilder, AIActionParser,
                                AIActionExecutor
  Centmond/AI/Intelligence/   — IntentRouter, Clarification, Insights,
                                CategorySuggester, BudgetRescue,
                                UserPreferences, ScenarioEngine
  Centmond/AI/Trust/          — TrustManager, TrustPolicy, AuditLog,
                                ConflictDetector, ActionHistory
  Centmond/AI/Automation/     — Workflow, EventBus, Proactive,
                                PromptVersioning
  Centmond/AI/Memory/         — AIMemory, MerchantMemory,
                                AssistantModes
  Centmond/AI/Financial/      — SafeToSpend, Optimizer,
                                SubscriptionOptimizer,
                                DuplicateDetector, RecurringDetector,
                                StatementImporter
  Centmond/AI/Ingestion/      — AIIngestion, AIOnboarding
  Centmond/Views/AI/          — All AI views

Hard rules:
- Read the iOS source file FIRST, then write the macOS version. Never
  blind-copy.
- Amounts are Decimal in Centmond, not cents (Int). Every cents()
  call and /100 conversion must be removed.
- All Store references become ModelContext operations.
- All Supabase manager calls become local SwiftData queries.
- ObservableObject → @Observable. @Published → direct properties.
- No UIKit. No UIApplication. No UIViewControllerRepresentable.
- Use CentmondTheme (existing design system) for all views.
- Apply Liquid Glass wherever appropriate (user standing rule).
- No camera — receipt scanner uses NSOpenPanel for file selection.
- Small reviewable commits per sub-phase.
- Between phases, wait for "go".
- xcodebuild not available — user verifies builds locally.
- No emojis in code or commit messages.

Start with Phase 0. Read, report, wait for "go".
```

---

## Phase 0 — Discovery & Dependency Setup (no AI logic yet)

```
Phase 0 — Setup only. Add llama.swift SPM dependency to Centmond and
verify it resolves. Create the empty folder structure. No AI logic yet.

Steps:
1. Read Centmond.xcodeproj or Package.swift to understand how
   dependencies are managed.
2. Add llama.swift v2.8728.0 SPM dependency:
   https://github.com/mattt/llama.swift
   (same version Balance iOS uses)
3. Create empty folder structure:
   Centmond/AI/Core/
   Centmond/AI/Intelligence/
   Centmond/AI/Trust/
   Centmond/AI/Automation/
   Centmond/AI/Memory/
   Centmond/AI/Financial/
   Centmond/AI/Ingestion/
4. Verify `import LlamaSwift` compiles (create a stub file if needed).
5. Copy the GGUF model path constant:
   /Users/mani/Desktop/SwiftProjects/gemma-4-E4B-it-Q6_K.gguf

Output: report what was done, wait for "go".
```

---

## P1 — AIManager + AIModels (model loading & inference)

```
P1 — Port AIManager.swift and AIModels.swift. These are the foundation
everything else depends on.

Read first:
- /Users/mani/Desktop/SwiftProjects/balance copy/balance/AI/AIManager.swift (696 lines)
- /Users/mani/Desktop/SwiftProjects/balance copy/balance/AI/AIModels.swift

Changes for macOS:
1. AIManager.swift:
   - Replace adaptive iOS RAM tiers with fixed M4 16GB params:
     gpuLayers=99, contextSize=8192, batchSize=512, maxTokens=2048
   - Keep the download flow (URLSession pattern) but adapt file paths
     for macOS Application Support
   - Dev model path: /Users/mani/Desktop/SwiftProjects/gemma-4-E4B-it-Q6_K.gguf
   - GGUF validation: same magic bytes check
   - ObservableObject → @Observable
   - @Published → direct stored properties
   - Keep the Gemma chat template (same family: E4B uses same template
     as E2B)
   - Token stripping: same <end_of_turn>/<start_of_turn> cleanup

2. AIModels.swift:
   - Copy as-is (pure data types, no platform dependency)
   - Verify ActionType enum covers all Centmond entities
     (Transaction, Account, Goal, Subscription, BudgetCategory,
     HouseholdMember — Centmond has HouseholdMember which iOS doesn't
     fully integrate)

Commits:
- P1.1: AIModels.swift (data types)
- P1.2: AIManager.swift (inference engine)

Write to: Centmond/AI/Core/
```

---

## P2 — System Prompt + Action Parser + Intent Router

```
P2 — Port the prompt/parsing/routing layer. These are mostly pure
Swift string processing with minimal platform dependency.

Read first:
- balance copy: AISystemPrompt.swift, AIActionParser.swift,
  AIIntentRouter.swift, AIIntentModel.swift

Changes for macOS:
1. AISystemPrompt.swift:
   - Update persona: "Centmond AI" (not "Balance AI")
   - Amounts are in DOLLARS (Decimal), not cents
   - Update entity references to match Centmond's SwiftData models
   - Add HouseholdMember context to system prompt
   - Reference the Centmond feature set (transfers, splits, tags,
     recurring, subscriptions, goals, household)

2. AIActionParser.swift:
   - Amounts: remove any ×100 conversion (Centmond uses Decimal
     directly, not cents)
   - Otherwise same parsing logic

3. AIIntentRouter.swift (1018 lines):
   - Copy regex patterns as-is (supports EN + Farsi)
   - Update any Store-specific references

4. AIIntentModel.swift:
   - Copy as-is (pure enum/struct)

Commits:
- P2.1: AISystemPrompt + AIActionParser
- P2.2: AIIntentRouter + AIIntentModel

Write to: Centmond/AI/Core/ and Centmond/AI/Intelligence/
```

---

## P3 — Context Builder (REWRITE — Store → SwiftData)

```
P3 — This is the hardest file to port. AIContextBuilder must be
completely rewritten for SwiftData.

Read first:
- balance copy: AIContextBuilder.swift
- Centmond models: Transaction.swift, Account.swift, BudgetCategory.swift,
  Goal.swift, Subscription.swift, HouseholdMember.swift,
  MonthlyBudget.swift, MonthlyTotalBudget.swift

The iOS version takes `Store` and reads store.transactions,
store.budgetsByMonth, etc. The macOS version must:

1. Accept ModelContext (not Store)
2. Fetch data using FetchDescriptor<Transaction>, etc.
3. Build the same text sections:
   - BUDGET: from MonthlyBudget + MonthlyTotalBudget entities
   - TRANSACTIONS: from Transaction entities (current month)
   - CATEGORY BREAKDOWN: from BudgetCategory + related transactions
   - GOALS: from Goal entities (direct SwiftData, not Supabase)
   - ACCOUNTS: from Account entities (direct SwiftData, not Supabase)
   - SUBSCRIPTIONS: from Subscription entities
   - HOUSEHOLD: from HouseholdMember entities + attributed transactions
4. Amounts are Decimal — format with CurrencyFormat helpers, not
   cents() function
5. Use BalanceService.isSpendingExpense() for spending calculations
   (excludes transfer legs)
6. Keep "focused" context builder variant (intent-scoped, smaller
   context for faster inference)
7. Add safeToSpend section and duplicate detection section

This file CANNOT be copied. It must be written fresh, reading the iOS
version for structure/sections but adapting every data access to
SwiftData.

Single commit: P3: AIContextBuilder for SwiftData

Write to: Centmond/AI/Core/
```

---

## P4 — Action Executor (REWRITE — Store → SwiftData)

```
P4 — Second hardest file. AIActionExecutor must be rewritten for
SwiftData mutations.

Read first:
- balance copy: AIActionExecutor.swift
- Centmond services: BalanceService.swift, TransferService.swift,
  TagService.swift, RecurringService.swift, SubscriptionService.swift

The iOS version does `store.transactions.append(tx)` and modifies
Store fields. The macOS version must:

1. Accept ModelContext (not inout Store)
2. For each action type:
   - addTransaction → create Transaction @Model, modelContext.insert()
     then BalanceService.recalculate(account:)
   - editTransaction → fetch by ID, mutate properties, bump updatedAt
   - deleteTransaction → modelContext.delete(), recalculate
   - transfer → use TransferService.createTransfer()
   - addRecurring → create RecurringTransaction @Model
   - setBudget → create/update MonthlyBudget / MonthlyTotalBudget
   - addGoal → create Goal @Model (local, not Supabase)
   - editGoal → fetch + mutate
   - addSubscription → create Subscription @Model
   - householdAssign → set transaction.householdMember
3. Tags: use TagService.resolve(input:in:existing:)
4. Undo data: snapshot before mutation for rollback
5. Return ExecutionResult with human-readable summary

This file CANNOT be copied. Write fresh, using iOS version as
structural reference.

Single commit: P4: AIActionExecutor for SwiftData

Write to: Centmond/AI/Core/
```

---

## P5 — Intelligence Layer (mostly copy)

```
P5 — Port the intelligence files. These are mostly pure Swift logic
with minor adaptations.

Files (read iOS version first, then write macOS version):

1. AIClarificationEngine.swift — copy as-is (pure logic)
2. AIInsightEngine.swift (661 lines) — adapt: replace Store access
   with ModelContext fetches. Use BalanceService predicates.
3. AICategorySuggester.swift — copy as-is (keyword matching)
4. AIBudgetRescue.swift — adapt: fetch budget data from SwiftData
   MonthlyBudget/MonthlyTotalBudget
5. AIUserPreferences.swift — copy as-is (UserDefaults-based)
6. AIScenarioEngine.swift — adapt: read SwiftData for simulations

Commits:
- P5.1: ClarificationEngine + CategorySuggester + UserPreferences
  (pure copy)
- P5.2: InsightEngine + BudgetRescue + ScenarioEngine (adapted)

Write to: Centmond/AI/Intelligence/
```

---

## P6 — Trust & Safety Layer (mostly copy)

```
P6 — Port the trust/audit/safety layer. Almost entirely pure Swift.

Files:
1. AITrustManager.swift — copy as-is (policy engine, no data access)
2. AITrustPolicy.swift — copy as-is (types only)
3. AIAuditLog.swift — copy as-is (UserDefaults persistence)
4. AIConflictDetector.swift — adapt: conflict checks need SwiftData
   fetch to find existing transactions
5. AIActionHistory.swift — copy as-is (in-memory + UserDefaults)

Commits:
- P6.1: TrustManager + TrustPolicy + ActionHistory + AuditLog (copy)
- P6.2: ConflictDetector (adapted for SwiftData)

Write to: Centmond/AI/Trust/
```

---

## P7 — Automation Layer (adapt)

```
P7 — Port workflows, proactive intelligence, event bus, prompt
versioning.

Files:
1. AIEventBus.swift — adapt: event sources need SwiftData triggers
   instead of Store.onChange
2. AIProactive.swift (850 lines) — adapt: morning briefing, budget
   risk, upcoming bills all need SwiftData fetches
3. AIWorkflow.swift (1349 lines, largest file) — adapt: month-end
   close, budget rebalance, transaction cleanup all mutate via
   ModelContext
4. AIPromptVersioning.swift — copy as-is (template management)

Commits:
- P7.1: EventBus + PromptVersioning
- P7.2: Proactive intelligence
- P7.3: Workflow engine

Write to: Centmond/AI/Automation/
```

---

## P8 — Memory & Modes (mostly copy)

```
P8 — Port AI memory, merchant learning, and assistant modes.

Files:
1. AIMemory.swift (778 lines) — copy as-is (UserDefaults persistence,
   no Store dependency)
2. AIMerchantMemory.swift — copy as-is (learns from execution
   results)
3. AIAssistantModes.swift — copy as-is (mode definitions + behavior
   modifiers)

Single commit: P8: AI memory, merchant learning, assistant modes

Write to: Centmond/AI/Memory/
```

---

## P9 — Financial Intelligence (adapt)

```
P9 — Port financial analysis tools.

Files:
1. AISafeToSpend.swift — adapt: budget/spending from SwiftData,
   amounts are Decimal not cents
2. AIOptimizer.swift (1085 lines) — adapt: optimization strategies
   need SwiftData access for budget/goal/subscription analysis
3. AISubscriptionOptimizer.swift — adapt: read Subscription @Model
4. AIDuplicateDetector.swift — adapt: fetch transactions via
   ModelContext
5. AIRecurringDetector.swift — adapt: analyze transaction patterns
   from SwiftData
6. AIStatementImporter.swift — adapt: file picker uses NSOpenPanel
   (not UIDocumentPicker), insert via modelContext

Commits:
- P9.1: SafeToSpend + SubscriptionOptimizer
- P9.2: DuplicateDetector + RecurringDetector
- P9.3: Optimizer
- P9.4: StatementImporter (NSOpenPanel)

Write to: Centmond/AI/Financial/
```

---

## P10 — Ingestion & Onboarding (adapt)

```
P10 — Port ingestion pipeline and AI onboarding.

Files:
1. AIIngestion.swift (977 lines) — adapt: staging area, merchant
   normalization, all inserts via ModelContext
2. AIOnboarding.swift (704 lines) — adapt: onboarding flow creates
   initial data via ModelContext, not Store

Commits:
- P10.1: AIIngestion
- P10.2: AIOnboarding

Write to: Centmond/AI/Ingestion/
```

---

## P11 — AI Views: Chat + Core UI

```
P11 — Port the main AI views. This is the user-facing layer.

Read the iOS version, then write macOS equivalents using
CentmondTheme and Liquid Glass.

Files:
1. AIChatView.swift (1627 lines, largest view):
   - Remove all UIKit: no UIApplication, no scrollDismissesKeyboard,
     no UIImpactFeedbackGenerator
   - Use Centmond's Haptics helper
   - Apply CentmondTheme spacing/typography/colors
   - macOS keyboard handling (onSubmit, no software keyboard)
   - Model status: loading/downloading/ready navbar indicator
   - Apply Liquid Glass to chat container and input bar
   - Use @Observable AIManager (not ObservableObject)
   - ModelContext from @Environment for action execution

2. ChatBubbleView.swift — adapt for CentmondTheme
3. TypingDotsView.swift — copy as-is (pure animation)
4. AISuggestedPrompts.swift — adapt FlowLayout for macOS
5. AIActionCard.swift (525 lines) — adapt for CentmondTheme
6. GroupedActionCard.swift — adapt for CentmondTheme

Commits:
- P11.1: ChatBubbleView + TypingDotsView + SuggestedPrompts
- P11.2: AIActionCard + GroupedActionCard
- P11.3: AIChatView (main chat interface)

Write to: Centmond/Views/AI/
```

---

## P12 — AI Views: Feature Screens

```
P12 — Port remaining AI views.

Files:
1. AIInsightBanner.swift — adapt for CentmondTheme
2. AIReceiptScannerView.swift — REWRITE: no camera on Mac.
   Use NSOpenPanel for image file selection. Vision OCR still works
   on macOS.
3. AIWorkflowView.swift (555 lines) — adapt
4. AIScenarioView.swift — adapt
5. AIActivityDashboard.swift (431 lines) — adapt
6. AIProactiveView.swift (432 lines) — adapt
7. AIMemoryView.swift (368 lines) — adapt
8. AIOptimizerView.swift (491 lines) — adapt
9. AIModeSettingsView.swift — adapt
10. AIIngestionView.swift (541 lines) — adapt
11. AIOnboardingView.swift (1058 lines) — adapt

Commits:
- P12.1: InsightBanner + ReceiptScanner
- P12.2: WorkflowView + ScenarioView
- P12.3: ActivityDashboard + ProactiveView
- P12.4: MemoryView + OptimizerView + ModeSettingsView
- P12.5: IngestionView + OnboardingView

Write to: Centmond/Views/AI/
```

---

## P13 — Integration & Wiring

```
P13 — Wire the AI system into Centmond's existing shell.

Read first:
- Centmond/CentmondApp.swift
- Centmond/Views/Shell/RootView.swift
- Centmond/Views/Shell/AppShell.swift (or equivalent navigation)
- Centmond/Views/Dashboard/ (for insight banners, AI button)
- Centmond/Views/Settings/SettingsView.swift

Integration points:
1. CentmondApp.swift:
   - Initialize AIManager on launch
   - Load model from Application Support (or dev path)
   - Pass AIManager into environment

2. Navigation:
   - Add AI chat as a sidebar item or floating button
   - Wire "Ask AI" from dashboard

3. Dashboard:
   - Budget rescue banner (AIBudgetRescue)
   - Morning briefing (AIProactive)
   - AI insight row (AIInsightBanner)

4. Settings:
   - AI model management section (download, status, size)
   - Mode selection (Advisor/Assistant/Autopilot/CFO)
   - Morning/weekly briefing toggles
   - Trust preferences
   - AI Activity link

5. Store onChange → SwiftData equivalent:
   - On Transaction insert/delete/update: refresh insights, evaluate
     budget rescue, train categorizer, post events to EventBus
   - Use SwiftData's notification or a thin wrapper

6. Model download:
   - Production: download from HuggingFace (same URLSession pattern)
   - Dev: load from /Users/mani/Desktop/SwiftProjects/gemma-4-E4B-it-Q6_K.gguf

Commits:
- P13.1: AIManager environment + model loading
- P13.2: Navigation wiring (sidebar + dashboard)
- P13.3: Settings AI section
- P13.4: SwiftData change hooks (insight refresh, event bus)
```

---

## P14 — Polish & QA

```
P14 — Final polish pass.

1. Liquid Glass audit: every AI view surface reviewed
2. CentmondTheme consistency: no magic numbers in AI views
3. Test all action types end-to-end:
   - Add/edit/delete transaction via AI
   - Transfer via AI
   - Set budget via AI
   - Create goal via AI
   - Assign household member via AI
4. Test all intelligence features:
   - Intent routing (EN + Farsi)
   - Proactive briefings
   - Budget rescue
   - Safe-to-spend
   - Duplicate detection
5. Model performance: verify generation speed on M4
6. Context window: verify 8192 tokens doesn't overflow
7. Memory usage: monitor during generation (should stay under 10GB)
8. Warning sweep: zero compiler warnings in AI files

Final commit: P14: AI release QA pass complete
```

---

## File Classification (copy vs adapt vs rewrite)

### Copy as-is (pure Swift, no platform/data dependency) — 13 files
```
AIModels.swift, AIIntentModel.swift, AICategorySuggester.swift,
AIUserPreferences.swift, AIClarificationEngine.swift,
AITrustManager.swift, AITrustPolicy.swift, AIAuditLog.swift,
AIActionHistory.swift, AIPromptVersioning.swift, AIMemory.swift,
AIMerchantMemory.swift, AIAssistantModes.swift
```

### Adapt (minor changes: Store→SwiftData, UIKit→AppKit) — 17 files
```
AISystemPrompt.swift, AIActionParser.swift, AIIntentRouter.swift,
AIInsightEngine.swift, AIBudgetRescue.swift, AIScenarioEngine.swift,
AIConflictDetector.swift, AIEventBus.swift, AIProactive.swift,
AIWorkflow.swift, AISafeToSpend.swift, AIOptimizer.swift,
AISubscriptionOptimizer.swift, AIDuplicateDetector.swift,
AIRecurringDetector.swift, AIIngestion.swift, AIOnboarding.swift
```

### Rewrite (fundamental interface change) — 5 files
```
AIManager.swift (macOS params + @Observable)
AIContextBuilder.swift (Store → ModelContext)
AIActionExecutor.swift (Store → ModelContext)
AIStatementImporter.swift (UIDocumentPicker → NSOpenPanel)
AIReceiptScanner.swift (camera → file only)
```

### Views — all adapt for CentmondTheme + Liquid Glass — 17 files
```
AIChatView.swift, ChatBubbleView.swift, TypingDotsView.swift,
AISuggestedPrompts.swift, AIActionCard.swift, GroupedActionCard.swift,
AIInsightBanner.swift, AIReceiptScannerView.swift,
AIWorkflowView.swift, AIScenarioView.swift,
AIActivityDashboard.swift, AIProactiveView.swift,
AIMemoryView.swift, AIOptimizerView.swift, AIModeSettingsView.swift,
AIIngestionView.swift, AIOnboardingView.swift
```

---

## Commit Message Style

```
P#.x: short verb phrase

1-2 sentence body explaining WHY, not what.
```

Example:
```
P3: AIContextBuilder reads SwiftData instead of Store

The iOS version consumed a Codable Store struct; Centmond uses
SwiftData @Model entities, so every data access path was rewritten
to use ModelContext fetch descriptors while keeping the same prompt
section structure the model was trained to expect.
```

---

## Between-Phase Protocol

1. Claude finishes a phase and reports summary
2. User verifies build in Xcode
3. User says "go" for next phase
4. If new scope discovered, Claude surfaces it before expanding
