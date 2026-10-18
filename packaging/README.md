# Postie app icon

## Padding refinement — 18 October 2026

Production master updated with more internal blue space. Prior master preserved as `docs/mockups/app-icons-20261018/postie-production-before-padding.png`. Built-in image tool exact prompt:

Use case: precise-object-edit. Correct ONLY internal padding of this approved macOS app icon. Keep the blue rounded-square tile exactly same size and shape and position in square canvas. Uniformly scale the ENTIRE motorcycle illustration including mailbag, wheels, headlight, engine, exhaust and its shadow to 88 percent of its current size about its visual center. This creates noticeably more blue breathing room particularly to left of bag/rear fender and right of front tire. Center the resulting bike-and-bag group comfortably within blue tile. Preserve relative proportions of ALL motorcycle parts, huge red-bordered cream braces bag, red body, open spoke-free wheel interiors and cream hubs, same materials/colors/light. Do not redesign anything. Extend the existing blue background naturally into vacated space. Exterior beyond rounded square must be fully transparent, clean with no stray pixels, no white border or canvas. No text or added objects.


Selected 18 October 2026: raised, narrower braces mailbag on red CT-style bike against slate blue (`docs/mockups/app-icons-20261018/postie-ct-slate-raised-bag-v11.png`).

`Postie.png` is the transparent exterior production master; generated with the built-in image tool from the selected concept. `Postie.icns` contains standard 16, 32, 128, 256 and 512 point representations at 1x/2x. Apple `sips --resampleHeightWidth` and `iconutil --convert icns` generated the representations. Makefile copies the ICNS into Contents/Resources before signing; CFBundleIconFile names it.

## Production extraction prompt

Use case: background-extraction. Prepare this approved macOS app icon for packaging. Remove ONLY the white canvas OUTSIDE the blue rounded-square app tile, making that exterior fully transparent including corners. Keep the entire blue rounded square and ALL artwork inside it exactly unchanged: red motorcycle, raised narrow red-bordered cream braces bag, black tires with open blue interiors and small cream hubs, saddle, engine, exhaust, headlight, proportions and colors. Do not redesign, move, crop, add, or remove any part of the icon. Output square PNG with genuine alpha transparency outside the tile. Preserve subtle edge antialiasing; no white halo.
