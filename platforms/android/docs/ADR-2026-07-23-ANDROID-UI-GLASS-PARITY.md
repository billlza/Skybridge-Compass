# ADR 2026-07-23: Android UI and glass parity

Status: accepted for Android UI implementation.

## Context

SkyBridge uses the mature iOS/macOS product as its interaction and visual baseline. Android must preserve the same hierarchy, grouping, semantic colors, and material depth without claiming access to Apple-only Liquid Glass APIs.

Compose `RenderEffect` blurs a rendered subtree, including its content; it is not a stable backdrop sampler. Applying it to a card would soften text and controls rather than reproduce Apple system material.

## Decision

1. Keep UI state unidirectional: screen ViewModels own persisted state; section composables receive immutable state and intents.
2. Use `IOSParityTokens` as the single source for cross-platform color, shape, spacing, and glass constants. Dynamic Material colors may supply accessible foreground/background roles, but must not redefine parity geometry.
3. Use `LiquidGlassSurface` as a deterministic layered material: translucent tint, specular highlight, center bloom, restrained cyan/purple rim, depth shade, and border.
4. Call the intensity control `opticalDepth`; it is not backdrop blur. The legacy `blurRadius` argument remains a temporary source-compatible alias and must not be used in new settings UI.
5. Keep decoration behind descendants so typography and controls remain crisp. `GlassRenderingQuality.Reduced` lowers decoration without changing layout.
6. Settings use grouped containers, inset dividers, common icon tiles, semantic foreground colors, 22 dp section corners, and bottom-navigation clearance.
7. Android should match Apple behavior and hierarchy, not copy platform-inappropriate controls. Native Android accessibility, touch targets, back behavior, lifecycle, and window insets remain mandatory.

## Consequences

- The effect is an intentional Android approximation, not native Apple Liquid Glass or true backdrop refraction.
- Glass rendering remains deterministic across API 36+ devices and does not depend on GPU blur quirks.
- New settings surfaces must use grouped primitives and shared tokens instead of local alpha/shape constants.
- Visual parity is accepted only after dark/light, Chinese/English/Japanese, narrow-width, and large-font review against current Apple reference captures.

## Relationship to other architecture documents

This ADR governs Compose UI architecture and visual parity. `ADR-2026-07-01-ANDROID-P2P-QPERIAPT-STACK.md` remains authoritative for protocol, security, platform baseline, and module boundaries. Older 2025 UI examples are historical guidance where they conflict with this ADR.