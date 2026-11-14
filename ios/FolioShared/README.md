# FolioShared: the screens both apps use

Two iPhone apps are built from this folder, so a change here shows up in **both**:

| App | Project | Where it keeps its own code |
|---|---|---|
| **Folio** (the product) | `ios/FolioFinance.xcodeproj` | `ios/FolioFinance/`, `ios/FolioWidgets/` |
| **Folio Desktop** (Matt's own, reads his Mac) | `Balance Sheet/ios/FinancialPicture/FinancialPicture.xcodeproj` | `FinancialPicture/App/`, `FinancialPictureWidgets/` |

## Where things go

- `FolioShared/` — every screen, model and the `Endpoint` list. **Both apps. Change screens here, once.**
- `FolioWidgetShared/` — the home-screen widgets (all three) and `WidgetSnapshot`. Both apps' widgets.
- `FolioFinance/` and `FolioWidgets/` — Folio only: login, intro, paywall, Plaid linking, Stripe, its `AuthManager`, `APIClient`, Settings.
- Folio Desktop's own folder — Face ID, `FeedBackend` (answers the screens from the Mac's iCloud file), the Mac-only pages, its Settings.

## What each app must provide (the screens call these)

`AuthManager` (with `withFreshToken`, `isDemo`, `currentEmail`, `hasSeenSetup`, `markSetupSeen`, `logout`, `deleteAccount`),
`ProfileMenu`, `SettingsView`, `PlaidLinkSheet`, `PlaidConnectButton`, `BankSync`, `BankSyncResult`, `MainTabView` / `RootView`.

## The one switch

Folio Desktop's targets define the Swift flag **`PERSONAL`**. Inside a shared file, `#if PERSONAL … #else … #endif` is how a screen differs
between the apps (no "+" add buttons, Mac's category list, opens on Spending). Everything else is identical.
Keep `#if PERSONAL` blocks small, and put anything bigger in the app's own folder instead.

## Rules so the two never get mixed up

1. A new screen or fix → `FolioShared/`. Build **both** apps before you push.
2. Something only one app needs → that app's own folder, never inside `FolioShared/`.
3. Light/dark mode: use `.appAppearance()` at each app's root and `AppearancePicker()` in each Settings, so they match.
4. Widgets: only edit `FolioWidgetShared/`; each app just says where its `WidgetSnapshot` comes from.
