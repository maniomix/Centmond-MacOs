import SwiftUI

// MARK: - Content model

/// One self-contained tutorial entry for a section of the app.
/// Lives in `SectionHelpLibrary` keyed by `Screen`.
struct SectionHelp {
    let screen: Screen
    let tagline: String                     // one-liner shown in the inline strip
    let heroIcon: String                    // SF Symbol shown in the popover hero
    let heroTint: Color                     // gradient tint for hero + accents
    let elevatorPitch: String               // 1-2 sentence "what is this place?"
    let blocks: [Block]                     // ordered, color-coded callouts
    let steps: [Step]                       // numbered "how to" cards
    let proTips: [String]                   // bulleted pro tips at the bottom
    let faq: [QA]                           // optional Q&A list

    struct Block: Identifiable {
        enum Kind { case what, why, how, watchOut }
        let id = UUID()
        let kind: Kind
        let title: String
        let body: String
    }

    struct Step: Identifiable {
        let id = UUID()
        let number: Int
        let title: String
        let body: String
        let icon: String
    }

    struct QA: Identifiable {
        let id = UUID()
        let q: String
        let a: String
    }
}

extension SectionHelp.Block.Kind {
    var color: Color {
        switch self {
        case .what: CentmondTheme.Colors.accent
        case .why: CentmondTheme.Colors.projected
        case .how: CentmondTheme.Colors.positive
        case .watchOut: CentmondTheme.Colors.warning
        }
    }
    var label: String {
        switch self {
        case .what: "WHAT IT IS"
        case .why: "WHY IT MATTERS"
        case .how: "HOW IT WORKS"
        case .watchOut: "HEADS UP"
        }
    }
    var icon: String {
        switch self {
        case .what: "sparkles"
        case .why: "heart.fill"
        case .how: "wand.and.stars"
        case .watchOut: "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Library

enum SectionHelpLibrary {
    static func entry(for screen: Screen) -> SectionHelp? { entries[screen] }

    private static let entries: [Screen: SectionHelp] = [
        .dashboard: dashboard,
        .reports: reports,
        .aiChat: aiChat,
        .transactions: transactions,
        .budget: budget,
        .accounts: accounts,
        .goals: goals,
        .subscriptions: subscriptions,
        .recurring: recurring,
        .forecasting: forecasting,
        .insights: insights,
        .netWorth: netWorth,
        .household: household,
        .settings: settings,
        .aiPredictions: aiPredictions,
        .reviewQueue: reviewQueue,
    ]

    // MARK: Dashboard

    private static let dashboard = SectionHelp(
        screen: .dashboard,
        tagline: "Your money at a glance — income, spending, what's safe to spend.",
        heroIcon: "house.fill",
        heroTint: CentmondTheme.Colors.accent,
        elevatorPitch: "The Dashboard is your home base. Every important number for the month — what came in, what went out, and what's safe to spend — sits in one place so you can answer 'how am I doing?' in under five seconds.",
        blocks: [
            .init(kind: .what, title: "A live monthly snapshot",
                  body: "Four big tiles at the top show Income, Spending, what's left in your budget (Remaining), and Safe to Spend — a smart number that already subtracts upcoming bills."),
            .init(kind: .why, title: "Decisions, not data dumps",
                  body: "You shouldn't have to do math in your head. Every chart here answers a real-life question: can I order takeout tonight? Am I on pace? What's eating my budget?"),
            .init(kind: .how, title: "Updates as you go",
                  body: "Add a transaction, and every tile and chart on this screen recalculates instantly. No refresh button needed."),
            .init(kind: .watchOut, title: "Month switcher in the sidebar",
                  body: "All numbers reflect the month picked in the sidebar arrows. Jumping months changes everything you see here."),
        ],
        steps: [
            .init(number: 1, title: "Read the four tiles",
                  body: "Green is good (money in or buffer left). Red means you've gone over. The Safe to Spend tile is the one to trust day-to-day.",
                  icon: "square.grid.2x2.fill"),
            .init(number: 2, title: "Scan Cash Flow",
                  body: "The big chart shows income vs spending across the month. Bars going above your income line = a red-flag week.",
                  icon: "chart.bar.fill"),
            .init(number: 3, title: "Check the Insight strip",
                  body: "Centmond surfaces 1–3 things worth noticing — a new big subscription, a category you blew past, a streak. Tap one to dive in.",
                  icon: "lightbulb.fill"),
            .init(number: 4, title: "Open recent activity",
                  body: "Bottom-left shows your most recent transactions. Click any row to inspect or recategorize.",
                  icon: "list.bullet.rectangle.fill"),
        ],
        proTips: [
            "Hover any chart to see exact daily numbers.",
            "The AI banner up top is a one-click shortcut — ask it 'why am I red this month?'",
            "Click a category in the breakdown donut to filter Transactions to just that category.",
        ],
        faq: [
            .init(q: "Why is Safe to Spend lower than Remaining?",
                  a: "Safe to Spend already subtracts the bills and subscriptions still due before month-end. Remaining is just budget minus actual spend so far."),
            .init(q: "Some numbers look stale.",
                  a: "Pull-to-refresh isn't needed — but check the month picker. You may be looking at a past month."),
        ]
    )

    // MARK: Reports

    private static let reports = SectionHelp(
        screen: .reports,
        tagline: "Build a custom report, then export it as CSV, Excel, or a polished PDF.",
        heroIcon: "doc.text.fill",
        heroTint: CentmondTheme.Colors.projected,
        elevatorPitch: "Reports is where Centmond turns your data into something you can hand to your accountant, your partner, or your future self. Pick a date range, choose which sections you care about, and export — that's it.",
        blocks: [
            .init(kind: .what, title: "A composable report",
                  body: "Toggle on the sections you want — Spending by Category, Top Merchants, Net Worth, Subscriptions, and more. The preview rebuilds live as you toggle."),
            .init(kind: .why, title: "Three formats, three jobs",
                  body: "CSV is for nerds and spreadsheets. Excel keeps formatting and percentages. PDF is the polished one with a cover page, table of contents, and color-coded charts — perfect for sharing."),
            .init(kind: .how, title: "Schedule it to repeat",
                  body: "Hit Schedule and Centmond will rebuild this exact report every month (or week, or quarter) and drop the file into a folder you choose. Hands-off."),
            .init(kind: .watchOut, title: "Empty range = empty report",
                  body: "If you pick 'Custom' with a future start date, you'll get a blank report. The header always shows the real transaction count, so trust that number."),
        ],
        steps: [
            .init(number: 1, title: "Pick your range",
                  body: "Use the chips — MTD, YTD, Last 12 months — or click Custom for a date picker.",
                  icon: "calendar"),
            .init(number: 2, title: "Choose sections",
                  body: "Open the Sections menu to toggle each block on or off. Order in the preview = order in the export.",
                  icon: "checklist"),
            .init(number: 3, title: "Filter (optional)",
                  body: "Open Filters to narrow by account, category, or household member. Useful for tax-prep on a specific card.",
                  icon: "line.3.horizontal.decrease.circle"),
            .init(number: 4, title: "Export or schedule",
                  body: "CSV (⌘⇧C), Excel (⌘⇧X), PDF (⌘P). Or hit Schedule to make it recurring.",
                  icon: "square.and.arrow.up"),
        ],
        proTips: [
            "PDFs have clickable Table of Contents entries — try it.",
            "Excel exports use real currency formatting, not raw numbers.",
            "Schedules keep running even if you forget about them — check Settings → Scheduled Reports to manage them.",
        ],
        faq: [
            .init(q: "Why is the PDF different from what I see on screen?",
                  a: "The PDF is a full document with a cover, TOC, and per-section pages. The on-screen preview is a working view — they share data, not layout."),
            .init(q: "Can I export only one section?",
                  a: "Yes. Toggle off everything else in the Sections menu."),
        ]
    )

    // MARK: AI Chat

    private static let aiChat = SectionHelp(
        screen: .aiChat,
        tagline: "Ask anything about your money in plain language. The AI sees your data — privately, on your Mac.",
        heroIcon: "brain.head.profile.fill",
        heroTint: CentmondTheme.Colors.accent,
        elevatorPitch: "AI Chat is a private financial assistant that runs entirely on your Mac. Nothing leaves your computer. Ask it questions, ask it to make changes, or just brainstorm — it knows your transactions, budgets, goals, and habits.",
        blocks: [
            .init(kind: .what, title: "Local. Private. Yours.",
                  body: "The AI model lives on your Mac. No cloud, no API calls, no analytics. You can pull the network cable and it still works."),
            .init(kind: .why, title: "It already knows the context",
                  body: "You don't need to paste data. Ask 'what did I spend on coffee last month?' and it answers — because it has full read access to your Centmond data."),
            .init(kind: .how, title: "It can take actions too",
                  body: "Ask it to create a budget, recategorize a transaction, or add a goal. It will propose the change as a card you approve before anything is written."),
            .init(kind: .watchOut, title: "Still in beta",
                  body: "The AI can be wrong. Always double-check numbers it cites, especially for tax or legal decisions. Action cards always need your approval — nothing happens silently."),
        ],
        steps: [
            .init(number: 1, title: "Start with a question",
                  body: "Try 'how much did I spend last week?' or 'am I on track for my emergency fund?' Plain English works.",
                  icon: "text.bubble.fill"),
            .init(number: 2, title: "Use @ to mention people",
                  body: "Type @ to tag a household member — 'how much does @ali owe me?' is a valid question.",
                  icon: "at"),
            .init(number: 3, title: "Review action cards",
                  body: "If it suggests a change (new budget, category move), an action card appears. Tap Approve to apply, Reject to discard.",
                  icon: "checkmark.seal.fill"),
            .init(number: 4, title: "Save useful chats",
                  body: "Open the chat history sidebar to revisit past conversations. They're stored locally too.",
                  icon: "clock.arrow.circlepath"),
        ],
        proTips: [
            "Suggested questions appear under the input — tap one if you're stuck.",
            "The mode indicator (top-right) tells you whether the model is loaded and thinking.",
            "Long chats slow down — start a fresh chat (square+pencil icon) for unrelated topics.",
        ],
        faq: [
            .init(q: "Does my data leave my Mac?",
                  a: "No. The model is local. Centmond does not send your transactions, account info, or chat history to any server."),
            .init(q: "Why is the first answer slow?",
                  a: "The model loads into memory on first use. After that, it stays warm and answers fast."),
            .init(q: "Can it delete things?",
                  a: "Only with your explicit approval via an action card. It cannot silently change or delete data."),
        ]
    )

    // MARK: Transactions

    private static let transactions = SectionHelp(
        screen: .transactions,
        tagline: "Every dollar you've spent or earned, in one searchable list.",
        heroIcon: "list.bullet.rectangle.fill",
        heroTint: CentmondTheme.Colors.accent,
        elevatorPitch: "Transactions is the source of truth. Add, edit, search, recategorize, split, share — anything that touches a single line of money happens here.",
        blocks: [
            .init(kind: .what, title: "Your full ledger",
                  body: "Every income, expense, and transfer ever recorded — across all accounts, members, and dates."),
            .init(kind: .why, title: "Categorization = good budgets",
                  body: "Centmond can only build smart budgets and forecasts if your transactions are correctly categorized. This is the screen where you fix that."),
            .init(kind: .how, title: "Right-click is power-user mode",
                  body: "Every row has a context menu: View, Duplicate, Copy Amount, Split by Category, Share Across Members, change Category/Account, mark Reviewed, Delete."),
            .init(kind: .watchOut, title: "Filter chips stack",
                  body: "If results look thin, check the chip bar — month + household member + category filters all narrow the list at once."),
        ],
        steps: [
            .init(number: 1, title: "Add a transaction",
                  body: "Hit the + button. Pick income, expense, or transfer; fill amount, category, account, date.",
                  icon: "plus.circle.fill"),
            .init(number: 2, title: "Search & filter",
                  body: "Type in the search box, or tap the chip bar above the list to narrow by date, account, or member.",
                  icon: "magnifyingglass"),
            .init(number: 3, title: "Bulk-select",
                  body: "Cmd-click rows or use Select All. Bulk delete, recategorize, or mark reviewed in one move.",
                  icon: "checkmark.square.fill"),
            .init(number: 4, title: "Split or share",
                  body: "Right-click a transaction to split across categories or share with household members for accurate balances.",
                  icon: "rectangle.split.3x1.fill"),
        ],
        proTips: [
            "CSV import lives in Settings → Data — it auto-detects most bank export formats.",
            "Subscription chip on a row links it to a recurring service for forecasting.",
            "The inspector (right side) updates live as you click rows.",
        ],
        faq: [
            .init(q: "Why are some rows greyed out?",
                  a: "Those are 'Pending' status — usually imported but not yet reviewed. Mark them Reviewed to clear the muting."),
            .init(q: "Can I undo a delete?",
                  a: "Single deletes can be undone with Cmd-Z. Bulk deletes show a confirm and are permanent."),
        ]
    )

    // MARK: Budget

    private static let budget = SectionHelp(
        screen: .budget,
        tagline: "Set monthly limits per category. Watch them fill up. Stay on track.",
        heroIcon: "chart.pie.fill",
        heroTint: CentmondTheme.Colors.positive,
        elevatorPitch: "A budget is just a promise to yourself. Centmond makes it a visual one — colored bars, a heatmap, and clear 'safe to spend' numbers so you always know where you stand.",
        blocks: [
            .init(kind: .what, title: "Per-category envelopes",
                  body: "Each category gets a monthly cap. Spend within it = green. Approaching the cap = amber. Over = red."),
            .init(kind: .why, title: "Visible limits change behavior",
                  body: "Studies show people who see their budget daily spend ~20% less. The heatmap is built for exactly that."),
            .init(kind: .how, title: "Limits are sticky, not nags",
                  body: "Going over a budget is allowed — Centmond won't block a transaction. But the dashboard tile turns red and the next month's safe-to-spend recalibrates."),
            .init(kind: .watchOut, title: "Total budget vs. category sums",
                  body: "Your category caps don't have to add up to your income. The 'Total budget' card shows the sum so you can spot the gap."),
        ],
        steps: [
            .init(number: 1, title: "Pick a category",
                  body: "Click any row in the list to set or change its monthly cap. €0 = uncapped (won't trigger warnings).",
                  icon: "tag.fill"),
            .init(number: 2, title: "Read the heatmap",
                  body: "Rows are categories, columns are months. Darker = higher spend relative to its cap.",
                  icon: "square.grid.3x3.fill"),
            .init(number: 3, title: "Roll over to next month",
                  body: "Centmond carries category caps forward automatically. Tweak per-month from the inspector.",
                  icon: "arrow.right.circle.fill"),
        ],
        proTips: [
            "Right-click a category for 'copy to all months' or 'reset for this month'.",
            "Use AI Chat: 'suggest a budget based on my last 3 months' — it'll propose caps you can approve.",
            "Categories with no spend in 90 days fade — consider archiving them.",
        ],
        faq: [
            .init(q: "Why is my heatmap all empty?",
                  a: "Either no transactions in that range, or your transactions don't have categories assigned. Open Transactions and check."),
            .init(q: "Can I have weekly budgets?",
                  a: "Not yet — Centmond uses monthly envelopes. You can simulate weekly by dividing your monthly cap by ~4."),
        ]
    )

    // MARK: Accounts

    private static let accounts = SectionHelp(
        screen: .accounts,
        tagline: "Every bank, card, and wallet you track — and what's in each one.",
        heroIcon: "building.columns.fill",
        heroTint: CentmondTheme.Colors.accent,
        elevatorPitch: "Accounts are containers. Every transaction belongs to one. Add your checking, savings, credit cards, and cash — Centmond will track balances and roll them up into your Net Worth.",
        blocks: [
            .init(kind: .what, title: "The places your money lives",
                  body: "Checking, savings, credit, loan, investment, cash. Each has a balance, a currency, and an owner."),
            .init(kind: .why, title: "Accounts power Net Worth",
                  body: "The Net Worth screen sums all asset accounts, subtracts all liability accounts, and tracks the trend over time. Garbage in, garbage out — keep balances current."),
            .init(kind: .how, title: "Balances auto-update",
                  body: "Every transaction tagged to an account adjusts its running balance. You only enter the starting balance once."),
            .init(kind: .watchOut, title: "Credit cards count as liabilities",
                  body: "A credit card balance is money you OWE, so it subtracts from net worth. Set the type correctly when adding."),
        ],
        steps: [
            .init(number: 1, title: "Add an account",
                  body: "Hit + Add Account. Name it (e.g. 'Revolut EUR'), pick the type, set today's balance.",
                  icon: "plus.app.fill"),
            .init(number: 2, title: "Tag transactions",
                  body: "When adding a transaction, pick which account it came from. Centmond updates that account's balance.",
                  icon: "link"),
            .init(number: 3, title: "Reconcile periodically",
                  body: "Compare Centmond's balance to your bank's. If off, add an 'adjustment' transaction to true it up.",
                  icon: "checkmark.shield.fill"),
        ],
        proTips: [
            "Use a clear naming convention: 'Bank · Type · Currency'.",
            "Archive old closed accounts instead of deleting — keeps history intact.",
            "Transfers between your own accounts use the 'transfer' type, not income/expense.",
        ],
        faq: [
            .init(q: "Can Centmond connect to my bank directly?",
                  a: "No — for privacy, Centmond is local-only. Use CSV import (Settings → Data) for bulk loading."),
            .init(q: "What about multiple currencies?",
                  a: "Each account can have its own currency. Reports use your default currency setting and show conversions where needed."),
        ]
    )

    // MARK: Goals

    private static let goals = SectionHelp(
        screen: .goals,
        tagline: "Save for the things you actually care about — and watch the bar fill up.",
        heroIcon: "target",
        heroTint: CentmondTheme.Colors.positive,
        elevatorPitch: "A goal turns 'I should save more' into 'I'm 47% of the way to my Japan trip'. Set a target, link contributions, and let Centmond track the rest.",
        blocks: [
            .init(kind: .what, title: "Targets with deadlines",
                  body: "Each goal has a name, a target amount, an optional deadline, and a category icon. That's it."),
            .init(kind: .why, title: "Specific beats vague",
                  body: "'Save for Japan, $4,000 by Sept' is 10× more motivating than 'save more'. Centmond shows pace and gap so you can adjust."),
            .init(kind: .how, title: "Income allocation",
                  body: "Mark a percentage of every income to auto-flow into goals. Or transfer manually from any account."),
            .init(kind: .watchOut, title: "Goals don't move money",
                  body: "Centmond tracks goal progress as bookkeeping — your actual savings still need to live in a real account. Pair every goal with a savings account in your head."),
        ],
        steps: [
            .init(number: 1, title: "Create a goal",
                  body: "Pick name, target, deadline, and a fun icon. Cards in the grid are equal-height for a reason — easier to scan.",
                  icon: "plus.circle.fill"),
            .init(number: 2, title: "Add contributions",
                  body: "Tap a goal → 'Add Contribution' to log a transfer toward it. Or set income allocation to do it automatically.",
                  icon: "arrow.right.to.line.compact"),
            .init(number: 3, title: "Watch the pace",
                  body: "Each card shows 'this month' and 'on pace / behind / ahead'. Behind = consider raising your auto-allocation.",
                  icon: "speedometer"),
        ],
        proTips: [
            "Try 'Transfer to goal' from a transaction to retroactively credit a deposit.",
            "Set a deadline even if it's flexible — pace tracking only works with one.",
            "AI Chat can suggest goals based on your spending patterns.",
        ],
        faq: [
            .init(q: "I hit my goal — what now?",
                  a: "Mark it complete from the goal card. It moves to the archive but contribution history stays."),
            .init(q: "Can a goal go negative?",
                  a: "No, contributions are additive. To 'unsave', delete the contribution from the goal's history."),
        ]
    )

    // MARK: Subscriptions

    private static let subscriptions = SectionHelp(
        screen: .subscriptions,
        tagline: "Find every recurring charge — Netflix, gym, that thing you forgot you signed up for.",
        heroIcon: "arrow.triangle.2.circlepath",
        heroTint: CentmondTheme.Colors.warning,
        elevatorPitch: "Subscriptions auto-detects services billing you on a schedule and gives you one place to review them. Most people find $30+/month they didn't know about.",
        blocks: [
            .init(kind: .what, title: "Automatic detection",
                  body: "Centmond scans your transactions for repeating charges (same merchant, similar amount, regular interval) and surfaces them as subscription candidates."),
            .init(kind: .why, title: "Subscriptions are silent budget killers",
                  body: "A $9.99 charge feels like nothing. Twelve of them is $1,440/year. The Optimizer card shows your worst offenders."),
            .init(kind: .how, title: "Confirm or dismiss",
                  body: "Detected subs land in a review queue. Approve = added to forecasting. Dismiss = Centmond stops suggesting it."),
            .init(kind: .watchOut, title: "False positives",
                  body: "Variable bills (utilities, restaurants you frequent) sometimes get flagged. Dismiss them and Centmond learns."),
        ],
        steps: [
            .init(number: 1, title: "Run detection",
                  body: "Hit 'Detect' to scan recent transactions. Candidates appear with confidence scores.",
                  icon: "magnifyingglass.circle.fill"),
            .init(number: 2, title: "Review the list",
                  body: "For each candidate: Add (confirms it), Dismiss (ignores it), or click to edit details before adding.",
                  icon: "checkmark.circle.fill"),
            .init(number: 3, title: "Use the Optimizer",
                  body: "Sort by 'most expensive' or 'least used'. Cancel one and Centmond updates your forecast immediately.",
                  icon: "scissors"),
            .init(number: 4, title: "Forecast the year",
                  body: "The yearly cost card shows what your subs will run you over 12 months. Sobering.",
                  icon: "calendar.badge.clock"),
        ],
        proTips: [
            "Tag a transaction as a subscription from its right-click menu — instant link.",
            "Annual subs (insurance, domains) are detected by 12-month gaps — give it a year of data for best results.",
            "AI Chat: 'which subscriptions do I never use?' looks at last-charge dates.",
        ],
        faq: [
            .init(q: "It missed my Spotify charge.",
                  a: "Need at least 2-3 charges with similar amounts. Add it manually with + Add Subscription."),
            .init(q: "Can I track free trials?",
                  a: "Yes — set the next billing date to when the trial ends. Centmond will warn you 3 days before."),
        ]
    )

    // MARK: Recurring (beta)

    private static let recurring = SectionHelp(
        screen: .recurring,
        tagline: "Predictable transactions — rent, salary, bills — handled on autopilot.",
        heroIcon: "repeat",
        heroTint: CentmondTheme.Colors.projected,
        elevatorPitch: "Recurring is for transactions that follow a pattern: monthly salary, rent on the 1st, gym on the 15th. Centmond detects these from your history and adds them to your forecast.",
        blocks: [
            .init(kind: .what, title: "Detected, not entered",
                  body: "You don't add recurring transactions manually anymore. Centmond watches your transaction history and identifies the patterns automatically."),
            .init(kind: .why, title: "Read-only by design",
                  body: "Earlier versions let you edit recurring rows directly — that caused data crashes. Now they're surfaced from real transactions, which keeps things consistent."),
            .init(kind: .how, title: "Auto-confirmed over time",
                  body: "A pattern Centmond sees 3+ times with low variance becomes 'confirmed' and feeds into the Forecasting screen."),
            .init(kind: .watchOut, title: "Still in beta",
                  body: "Detection isn't perfect — irregular dates or amounts may not match. Future versions will let you nudge the detection."),
        ],
        steps: [
            .init(number: 1, title: "Let history accumulate",
                  body: "After 2-3 months of transactions, recurring rows start appearing automatically.",
                  icon: "clock.fill"),
            .init(number: 2, title: "Browse what was found",
                  body: "Each row shows merchant, amount, cadence (weekly/monthly/yearly), and next expected date.",
                  icon: "list.bullet"),
            .init(number: 3, title: "Trust the forecast",
                  body: "Confirmed recurring rows show up as 'pending' bars in the Forecasting screen and reduce your Safe to Spend.",
                  icon: "chart.line.uptrend.xyaxis"),
        ],
        proTips: [
            "If a recurring you expect doesn't show, just keep tagging the underlying transactions consistently.",
            "Income recurrings (salary) drive the income-allocation feature in Goals.",
        ],
        faq: [
            .init(q: "Why can't I edit or delete a recurring?",
                  a: "By design — they mirror real transactions. Edit the source transactions instead and detection re-runs."),
            .init(q: "What's the difference vs. Subscriptions?",
                  a: "Subscriptions are a curated, opt-in subset (services you pay for). Recurring is broader: any pattern, including salary and rent."),
        ]
    )

    // MARK: Forecasting

    private static let forecasting = SectionHelp(
        screen: .forecasting,
        tagline: "What will your money look like next month? Next 3? With this what-if change?",
        heroIcon: "chart.line.uptrend.xyaxis",
        heroTint: CentmondTheme.Colors.projected,
        elevatorPitch: "Forecasting projects your future cash flow based on your real spending patterns, recurring bills, and any what-if changes you sketch out. Useful for big decisions.",
        blocks: [
            .init(kind: .what, title: "Pattern-based projections",
                  body: "Centmond looks at your weekday-by-weekday spending baseline plus confirmed recurring bills, and extrapolates forward."),
            .init(kind: .why, title: "Plan before you act",
                  body: "Buying a car? Quitting a job? Sketch the change and see how runway/safe-to-spend change month by month."),
            .init(kind: .how, title: "What-if simulator",
                  body: "Add a hypothetical income, subscription, or one-off expense. The chart re-renders with a dotted scenario line."),
            .init(kind: .watchOut, title: "Forecasts get fuzzier far out",
                  body: "Months 1-3 are usually pretty accurate. Months 9-12 are vibes. Use the risk strip to see confidence."),
        ],
        steps: [
            .init(number: 1, title: "Read the runway",
                  body: "Top card: how many months until you'd hit zero if income stopped today. Lower = riskier.",
                  icon: "fuelpump.fill"),
            .init(number: 2, title: "Scan monthly cards",
                  body: "Each upcoming month shows projected income, spend, biggest line item, and end balance.",
                  icon: "calendar"),
            .init(number: 3, title: "Run a what-if",
                  body: "Add a scenario from the simulator panel. See how the chart changes. Save it or discard.",
                  icon: "wand.and.rays"),
            .init(number: 4, title: "Watch the risk strip",
                  body: "Highlights months that look tight (negative cash flow, big bills clustering, low buffer).",
                  icon: "exclamationmark.triangle.fill"),
        ],
        proTips: [
            "AI Chat: 'can I afford a $400/month car payment?' will generate a what-if for you.",
            "Confirmed recurring transactions are what makes forecasts accurate — keep that screen healthy.",
            "Forecast alerts (Settings) ping you when a risky month is approaching.",
        ],
        faq: [
            .init(q: "Why does my forecast keep changing?",
                  a: "Every new transaction shifts the baseline. That's the point — it's a living projection, not a static plan."),
            .init(q: "Can I export the forecast?",
                  a: "Yes — include the Forecasting section in a Report and export as PDF or Excel."),
        ]
    )

    // MARK: Insights

    private static let insights = SectionHelp(
        screen: .insights,
        tagline: "Centmond watches your data and surfaces things worth knowing.",
        heroIcon: "lightbulb.fill",
        heroTint: CentmondTheme.Colors.warning,
        elevatorPitch: "Insights are short, actionable nudges Centmond generates by watching for patterns: a category you blew past, a new big subscription, a streak worth celebrating, a bill that grew.",
        blocks: [
            .init(kind: .what, title: "Auto-generated cards",
                  body: "9 different detectors run on your data: spending spikes, budget overruns, new subscriptions, savings streaks, household imbalances, and more."),
            .init(kind: .why, title: "Surface what you'd miss",
                  body: "You can't watch every category every day. Insights are Centmond doing it for you and pinging only when something changed."),
            .init(kind: .how, title: "Engagement-gated",
                  body: "Dismiss an insight type once and Centmond shows you fewer of them. Act on one and that detector stays on."),
            .init(kind: .watchOut, title: "Not all are urgent",
                  body: "Some insights are FYI ('you spent 12% less on dining this month'). Color-coded — amber needs attention, blue is informational."),
        ],
        steps: [
            .init(number: 1, title: "Open the hub",
                  body: "All active insights live here, grouped by domain (spending, budgets, subscriptions, household, goals).",
                  icon: "rectangle.grid.2x2.fill"),
            .init(number: 2, title: "Tap to act",
                  body: "Each insight has a deeplink — opens the relevant screen pre-filtered to the issue.",
                  icon: "hand.tap.fill"),
            .init(number: 3, title: "Dismiss noise",
                  body: "Swipe or X to dismiss. Centmond learns what you don't care about and shows less of it.",
                  icon: "xmark.circle.fill"),
        ],
        proTips: [
            "The dashboard shows a 1-3 insight strip — the most urgent ones float to the top there too.",
            "AI Chat enriches insights — ask 'what's the story behind this insight?' for a longer explanation.",
            "Notifications can be enabled per-detector in Settings.",
        ],
        faq: [
            .init(q: "Why am I getting fewer insights than before?",
                  a: "Likely the auto-mute kicked in — Centmond noticed you weren't acting on a type and quieted it. Re-enable in Settings."),
            .init(q: "Can I create my own insight rules?",
                  a: "Not yet — current insights are built-in detectors. Custom rules are on the roadmap."),
        ]
    )

    // MARK: Net Worth

    private static let netWorth = SectionHelp(
        screen: .netWorth,
        tagline: "What you own minus what you owe — tracked over time.",
        heroIcon: "chart.bar.fill",
        heroTint: CentmondTheme.Colors.positive,
        elevatorPitch: "Net Worth is the single number that captures your financial health. Centmond computes it from your accounts, charts the trend, and breaks it into asset and liability categories.",
        blocks: [
            .init(kind: .what, title: "Assets minus liabilities",
                  body: "Sum of every asset account (checking, savings, investments) minus every liability (credit cards, loans, mortgage). One number, one chart."),
            .init(kind: .why, title: "Trend > snapshot",
                  body: "A single net-worth value is just a number. Watching it tick up over months is the actual financial-health signal."),
            .init(kind: .how, title: "Snapshot history",
                  body: "Centmond saves a snapshot weekly. The trend chart smooths these out. Real account balances drive the live number."),
            .init(kind: .watchOut, title: "Garbage in",
                  body: "Net Worth is only as accurate as your account balances. Reconcile every few weeks."),
        ],
        steps: [
            .init(number: 1, title: "Watch the trend",
                  body: "Top chart: net worth over time. Hover any point to see the exact number on that date.",
                  icon: "chart.xyaxis.line"),
            .init(number: 2, title: "Read the donuts",
                  body: "Asset breakdown (where your money lives) and liability breakdown (what you owe). Click a slice to filter.",
                  icon: "chart.pie.fill"),
            .init(number: 3, title: "Set milestones",
                  body: "Tag thresholds ($10k, $50k, debt-free) to celebrate when you cross them. Goals tie in too.",
                  icon: "flag.fill"),
            .init(number: 4, title: "Run a payoff sim",
                  body: "What if I throw $200/mo extra at this credit card? The simulator shows when you'd be debt-free.",
                  icon: "function"),
        ],
        proTips: [
            "Settings → Net Worth → Rebuild History recomputes snapshots from scratch if numbers look wrong.",
            "Account-level sparklines on each row show that account's individual trend.",
            "Export your net worth history as CSV for spreadsheet nerds.",
        ],
        faq: [
            .init(q: "My investment account isn't tracked properly.",
                  a: "Centmond doesn't fetch market prices. Update the account balance manually when you check your brokerage."),
            .init(q: "Why did net worth drop suddenly?",
                  a: "Usually a balance correction or a credit card statement landing. Hover the chart at the drop date to see the cause."),
        ]
    )

    // MARK: Household

    private static let household = SectionHelp(
        screen: .household,
        tagline: "Track who paid for what — and who owes who.",
        heroIcon: "person.2.fill",
        heroTint: CentmondTheme.Colors.accent,
        elevatorPitch: "Household turns 'wait, did you Venmo me for that?' into a clean ledger. Add household members, share expenses, and Centmond shows debts in plain language.",
        blocks: [
            .init(kind: .what, title: "Members + shares + settlements",
                  body: "Add the people you split money with. Tag transactions as 'shared' and pick the split. Record payments when someone settles up."),
            .init(kind: .why, title: "Stop doing math at dinner",
                  body: "No more spreadsheets, no more 'I think you owe me 12-ish'. The Who Owes Who panel says it directly."),
            .init(kind: .how, title: "Real ledger, not approximations",
                  body: "Every share is tracked at transaction-level. Settlements clamp to existing debts so you never go into reverse-debt accidentally."),
            .init(kind: .watchOut, title: "Delete = hard delete",
                  body: "Removing a member is permanent — earlier versions archived; now it deletes. Past shares with that member are cleaned up automatically."),
        ],
        steps: [
            .init(number: 1, title: "Add a member",
                  body: "Just name + email. No invites, no accounts — they don't need to install anything.",
                  icon: "person.crop.circle.badge.plus"),
            .init(number: 2, title: "Share a transaction",
                  body: "Right-click any transaction → Share Across Members. Pick equal split or custom percentages.",
                  icon: "rectangle.split.3x1.fill"),
            .init(number: 3, title: "Read 'Who Owes Who'",
                  body: "The hub shows direct statements: 'Ali owes you $25'. No mental math.",
                  icon: "arrow.left.arrow.right"),
            .init(number: 4, title: "Record payment",
                  body: "When someone pays you back, hit Record Payment. The debt clears.",
                  icon: "checkmark.circle.fill"),
        ],
        proTips: [
            "Use the Nudge button to copy a friendly reminder template to your clipboard.",
            "Filter Transactions by household member to see only their stuff.",
            "Recurring transactions inherit the same member — set it once for rent.",
        ],
        faq: [
            .init(q: "Can the other person see this in their own Centmond?",
                  a: "No — household tracking is local to your install. Centmond doesn't sync between users."),
            .init(q: "What if amounts don't quite balance after a settlement?",
                  a: "Centmond clamps settlements to existing debts. If something looks off, check the activity feed for the offending share."),
        ]
    )

    // MARK: Settings

    private static let settings = SectionHelp(
        screen: .settings,
        tagline: "Tune Centmond — currency, AI mode, scheduled reports, data import/export, danger zone.",
        heroIcon: "gearshape.fill",
        heroTint: CentmondTheme.Colors.textSecondary,
        elevatorPitch: "Settings is where you make Centmond yours. Pick your currency, manage scheduled reports, import or export data, tune the AI, and (carefully) wipe everything.",
        blocks: [
            .init(kind: .what, title: "Tabs by topic",
                  body: "General, AI, Notifications, Data, Net Worth, Scheduled Reports, Danger Zone — each has its own tab."),
            .init(kind: .why, title: "Defaults that follow you",
                  body: "Setting your default currency here applies to every new transaction, report, and export. One source of truth."),
            .init(kind: .how, title: "Data is yours, always",
                  body: "Export everything as CSV from Data tab. Import bank CSVs there too. Centmond's data lives on your Mac and you fully own it."),
            .init(kind: .watchOut, title: "Danger Zone is real",
                  body: "Erase All Data wipes everything and quits the app. There's no undo. You'll have to type DELETE ALL to confirm."),
        ],
        steps: [
            .init(number: 1, title: "Set your defaults",
                  body: "General tab: pick currency, week start, date format, theme.",
                  icon: "slider.horizontal.3"),
            .init(number: 2, title: "Manage scheduled reports",
                  body: "See every recurring report job, when it last ran, and where files are saved. Pause or delete from here.",
                  icon: "calendar.badge.clock"),
            .init(number: 3, title: "Import / export data",
                  body: "Data tab handles CSV import (auto-detects most banks) and full data export.",
                  icon: "square.and.arrow.up.on.square.fill"),
            .init(number: 4, title: "Tune the AI",
                  body: "Pick model, set creativity vs accuracy preference, manage chat history retention.",
                  icon: "brain.head.profile.fill"),
        ],
        proTips: [
            "The Help menu (⌘?) lets you replay onboarding any time.",
            "If notifications stop working, check System Settings → Notifications for Centmond too.",
            "Sample Data (Data tab) gives you a fully-populated demo set to play with.",
        ],
        faq: [
            .init(q: "Can I sync between Macs?",
                  a: "Not yet — local-only by design. iCloud sync is on the roadmap as an opt-in."),
            .init(q: "Where does Centmond store my data?",
                  a: "In a local SwiftData store inside the app's container. Export anytime to keep your own copy."),
        ]
    )

    // MARK: AI Predictions (beta)

    private static let aiPredictions = SectionHelp(
        screen: .aiPredictions,
        tagline: "AI looks at your habits and predicts what's coming — bills, spend, surprises.",
        heroIcon: "chart.line.text.clipboard.fill",
        heroTint: CentmondTheme.Colors.accent,
        elevatorPitch: "AI Predictions is a forward-looking view: instead of charts of what happened, it's the model's best guess at what will. Predicted bills, expected category spend, anomalies to watch for.",
        blocks: [
            .init(kind: .what, title: "Forward-looking, AI-driven",
                  body: "Local AI examines your last 90+ days and produces predictions: upcoming charges, expected category totals, likely anomalies."),
            .init(kind: .why, title: "Different from Forecasting",
                  body: "Forecasting is rules + patterns (deterministic). Predictions add the AI's pattern-recognition layer for fuzzier signals."),
            .init(kind: .how, title: "Confidence is shown",
                  body: "Each prediction has a confidence score. Trust the high-confidence ones; treat low ones as 'something to watch'."),
            .init(kind: .watchOut, title: "Beta feature",
                  body: "Predictions can be wrong. They are NOT instructions or commitments — just signals. Verify before acting on big ones."),
        ],
        steps: [
            .init(number: 1, title: "Open and skim",
                  body: "The screen splits into 'expected this month', 'upcoming bills', and 'anomaly watch'. Skim each card.",
                  icon: "eye.fill"),
            .init(number: 2, title: "Check confidence",
                  body: "High = the AI has seen this pattern many times. Low = it's a hunch.",
                  icon: "gauge.medium"),
            .init(number: 3, title: "Cross-check with Forecasting",
                  body: "If both this screen AND Forecasting flag the same month as risky, take it seriously.",
                  icon: "checkmark.shield.fill"),
        ],
        proTips: [
            "Refresh predictions after big new transactions for an updated view.",
            "Ask AI Chat 'why did you predict X?' for the reasoning.",
            "Predictions become more accurate as you log more transactions consistently.",
        ],
        faq: [
            .init(q: "Why is a prediction missing?",
                  a: "Need at least ~60 days of data and 3+ instances of a pattern. Sparse history = sparse predictions."),
            .init(q: "Can I dismiss a prediction?",
                  a: "Not currently — they auto-refresh as new data arrives. Future versions will let you mark them not-relevant."),
        ]
    )

    // MARK: Review Queue (currently hidden)

    private static let reviewQueue = SectionHelp(
        screen: .reviewQueue,
        tagline: "Transactions Centmond wants you to double-check before they're considered final.",
        heroIcon: "tray.fill",
        heroTint: CentmondTheme.Colors.warning,
        elevatorPitch: "The Review Queue is a filter, not a different list — it surfaces transactions that look incomplete or suspicious so you can fix or confirm them in batches.",
        blocks: [
            .init(kind: .what, title: "Smart triage",
                  body: "Detectors flag rows for review: missing category, unusual amount for the merchant, possible duplicate, suspicious foreign currency."),
            .init(kind: .why, title: "Quality > quantity",
                  body: "A clean ledger drives good budgets and forecasts. The queue is the easy way to bring everything to clean."),
            .init(kind: .how, title: "Approve, edit, or dismiss",
                  body: "Each row has inline actions. Once handled, it leaves the queue immediately."),
            .init(kind: .watchOut, title: "Currently hidden",
                  body: "This screen is dormant in the current build. Reach out if you'd like it re-enabled — the engine still runs in the background."),
        ],
        steps: [
            .init(number: 1, title: "Open the queue",
                  body: "(Currently hidden — no entry point.)",
                  icon: "tray"),
            .init(number: 2, title: "Triage in batches",
                  body: "Knock out missing categories first — biggest impact for least effort.",
                  icon: "checkmark.rectangle.stack.fill"),
        ],
        proTips: [
            "If re-enabled, the dashboard will show a Review strip with the top items.",
        ],
        faq: [
            .init(q: "Where did Review Queue go?",
                  a: "It was hidden by user request. The detectors still run; the UI is just commented out."),
        ]
    )
}

// MARK: - Help button (the "?" icon)

struct SectionHelpButton: View {
    let screen: Screen
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(CentmondTheme.Typography.heading3.weight(.semibold))
                .foregroundStyle(CentmondTheme.Colors.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("How does \(screen.displayName) work?")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let help = SectionHelpLibrary.entry(for: screen) {
                SectionHelpPopover(help: help)
            } else {
                Text("No tutorial yet for \(screen.displayName).")
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .padding()
            }
        }
    }
}

// MARK: - Popover (the floating tutorial window)

struct SectionHelpPopover: View {
    let help: SectionHelp

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.lg) {
                hero
                pitch
                blocksGrid
                stepsSection
                if !help.proTips.isEmpty { proTipsSection }
                if !help.faq.isEmpty { faqSection }
                footer
            }
            .padding(CentmondTheme.Spacing.xl)
        }
        .frame(width: 520, height: 640)
        .background(.ultraThinMaterial)
    }

    // Hero banner with gradient + giant icon

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [help.heroTint.opacity(0.55), help.heroTint.opacity(0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.lg, style: .continuous))

            HStack(alignment: .center, spacing: CentmondTheme.Spacing.md) {
                Image(systemName: help.heroIcon)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .centmondShadow(1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(help.screen.displayName.uppercased())
                        .font(CentmondTheme.Typography.overline)
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(help.tagline)
                        .font(CentmondTheme.Typography.heading2)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(CentmondTheme.Spacing.lg)
        }
        .frame(height: 130)
    }

    private var pitch: some View {
        Text(help.elevatorPitch)
            .font(CentmondTheme.Typography.body)
            .foregroundStyle(CentmondTheme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // 2-column grid of color-coded blocks

    private var blocksGrid: some View {
        let cols = [GridItem(.flexible(), spacing: CentmondTheme.Spacing.md),
                    GridItem(.flexible(), spacing: CentmondTheme.Spacing.md)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: CentmondTheme.Spacing.md) {
            ForEach(help.blocks) { block in
                blockCard(block)
            }
        }
    }

    private func blockCard(_ block: SectionHelp.Block) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: block.kind.icon)
                    .font(CentmondTheme.Typography.captionSmallSemibold.weight(.bold))
                Text(block.kind.label)
                    .font(CentmondTheme.Typography.overline)
                    .tracking(1.0)
            }
            .foregroundStyle(block.kind.color)

            Text(block.title)
                .font(CentmondTheme.Typography.bodyMedium)
                .foregroundStyle(CentmondTheme.Colors.textPrimary)

            Text(block.body)
                .font(CentmondTheme.Typography.caption)
                .foregroundStyle(CentmondTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(block.kind.color)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.xs))
        }
    }

    // Numbered "how to" steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            sectionHeader("How to use it", systemImage: "list.number")
            VStack(spacing: CentmondTheme.Spacing.sm) {
                ForEach(help.steps) { step in
                    stepRow(step)
                }
            }
        }
    }

    private func stepRow(_ step: SectionHelp.Step) -> some View {
        HStack(alignment: .top, spacing: CentmondTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(help.heroTint.opacity(0.18))
                Text("\(step.number)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(help.heroTint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: step.icon)
                        .font(CentmondTheme.Typography.captionSmallSemibold)
                        .foregroundStyle(help.heroTint)
                    Text(step.title)
                        .font(CentmondTheme.Typography.bodyMedium)
                        .foregroundStyle(CentmondTheme.Colors.textPrimary)
                }
                Text(step.body)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(CentmondTheme.Spacing.md)
        .background(CentmondTheme.Colors.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
    }

    // Pro tips

    private var proTipsSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            sectionHeader("Pro tips", systemImage: "sparkles")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(help.proTips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(CentmondTheme.Colors.warning)
                            .padding(.top, 6)
                        Text(tip)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(CentmondTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CentmondTheme.Colors.warningMuted.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        }
    }

    // FAQ

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
            sectionHeader("Common questions", systemImage: "questionmark.bubble.fill")
            VStack(alignment: .leading, spacing: CentmondTheme.Spacing.sm) {
                ForEach(help.faq) { qa in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(qa.q)
                            .font(CentmondTheme.Typography.bodyMedium)
                            .foregroundStyle(CentmondTheme.Colors.textPrimary)
                        Text(qa.a)
                            .font(CentmondTheme.Typography.caption)
                            .foregroundStyle(CentmondTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(CentmondTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CentmondTheme.Colors.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(CentmondTheme.Typography.captionSmall)
            Text("Your data stays on your Mac.")
                .font(CentmondTheme.Typography.caption)
        }
        .foregroundStyle(CentmondTheme.Colors.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(CentmondTheme.Typography.captionMedium.weight(.semibold))
            Text(title)
                .font(CentmondTheme.Typography.heading3)
        }
        .foregroundStyle(CentmondTheme.Colors.textPrimary)
    }
}

// MARK: - Inline tutorial strip (dismissible per-section)

/// A slim one-liner that sits at the top of a section, with a "Learn more"
/// button that opens the full popover. Dismissed per-screen via AppStorage.
struct SectionTutorialStrip: View {
    let screen: Screen
    @AppStorage private var dismissed: Bool

    init(screen: Screen) {
        self.screen = screen
        self._dismissed = AppStorage(wrappedValue: false, "tutorialStripDismissed.\(screen.rawValue)")
    }

    var body: some View {
        if dismissed {
            EmptyView()
        } else if let help = SectionHelpLibrary.entry(for: screen) {
            content(help)
        }
    }

    @ViewBuilder
    private func content(_ help: SectionHelp) -> some View {
        HStack(spacing: CentmondTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(help.heroTint.opacity(0.18))
                Image(systemName: help.heroIcon)
                    .font(CentmondTheme.Typography.bodyMedium.weight(.semibold))
                    .foregroundStyle(help.heroTint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Welcome to \(screen.displayName)")
                    .font(CentmondTheme.Typography.bodyMedium)
                    .foregroundStyle(CentmondTheme.Colors.textPrimary)
                Text(help.tagline)
                    .font(CentmondTheme.Typography.caption)
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            SectionHelpButton(screen: screen)

            Button {
                dismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(CentmondTheme.Typography.captionSmallSemibold.weight(.bold))
                    .foregroundStyle(CentmondTheme.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide this tip")
        }
        .padding(.horizontal, CentmondTheme.Spacing.md)
        .padding(.vertical, CentmondTheme.Spacing.sm)
        .background(CentmondTheme.Colors.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CentmondTheme.Radius.md, style: .continuous)
                .strokeBorder(CentmondTheme.Colors.strokeSubtle, lineWidth: 1)
        )
    }
}
