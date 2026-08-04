#!/bin/sh
# Monta dist/Colmeia.app a partir do build release (SwiftPM puro — sem xcodebuild).
# A UI procura colmeia-engine AO LADO do próprio executável (EngineConnection.swift),
# por isso engine e CLI vão juntos em Contents/MacOS.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/arm64-apple-macosx/release"
APP="$ROOT/dist/Colmeia.app"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for exe in ColmeiaApp colmeia-engine colmeia colmeia-sync; do
  cp "$BIN/$exe" "$APP/Contents/MacOS/$exe"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>pt_BR</string>
	<key>CFBundleExecutable</key>
	<string>ColmeiaApp</string>
	<key>CFBundleIconFile</key>
	<string>Colmeia.icns</string>
	<key>CFBundleIconName</key>
	<string>Colmeia</string>
	<key>CFBundleIdentifier</key>
	<string>com.mel.colmeia</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Colmeia</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.3.0</string>
	<key>CFBundleVersion</key>
	<string>14</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.mel.colmeia.join</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>colmeia</string>
			</array>
		</dict>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
		<!-- Hub remoto em ws:// (não-TLS) é o transporte de desenvolvimento do
		     colmeia-hub; sem isto a UI fica eternamente em "Reconectando ao Hub"
		     enquanto o colmeia-sync (socket TCP cru) continua funcionando. -->
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# Ícone: abelha 🐝 rasterizada via CoreText → iconset → icns. Opcional: se
# qualquer etapa falhar, o app fica sem ícone (não é erro de build).
ICONDIR="$(mktemp -d)/Colmeia.iconset"
mkdir -p "$ICONDIR"
if swift - "$ICONDIR" <<'SWIFT' 2>/dev/null
import AppKit
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let bg = NSBezierPath(roundedRect: NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9),
                          xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.16, alpha: 1).setFill()
    bg.fill()
    let emoji = "🐝" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 0.62)]
    let bounds = emoji.size(withAttributes: attrs)
    emoji.draw(at: NSPoint(x: (s - bounds.width) / 2, y: (s - bounds.height) / 2), withAttributes: attrs)
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    if size <= 512 {
        try? png.write(to: outDir.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}
SWIFT
then
  # Remover tamanhos que o iconutil não conhece (64 só existe como 32@2x).
  rm -f "$ICONDIR/icon_64x64.png" "$ICONDIR/icon_1024x1024.png"
  if iconutil -c icns "$ICONDIR" -o "$APP/Contents/Resources/Colmeia.icns" 2>/dev/null; then
    echo "ícone: ok"
  else
    echo "ícone: iconutil falhou (app fica sem ícone)"
  fi
else
  echo "ícone: geração falhou (app fica sem ícone)"
fi

# Por padrão usamos assinatura ad-hoc para desenvolvimento local. Para
# distribuição, informe uma identidade Apple de Developer ID e, opcionalmente,
# um perfil salvo no `notarytool`:
#
#   COLMEIA_CODESIGN_IDENTITY='Developer ID Application: Equipe (TEAMID)' \
#   COLMEIA_NOTARY_PROFILE='colmeia-release' ./scripts/build-app.sh
#
# O script nunca tenta notarizar silenciosamente: sem o perfil ele apenas
# produz o app assinado com a identidade escolhida.
SIGNING_IDENTITY="${COLMEIA_CODESIGN_IDENTITY:--}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
  # Assinatura ad-hoc: suficiente para abrir localmente, não para distribuição.
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$APP"
fi

NOTARY_PROFILE="${COLMEIA_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ]; then
  if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "erro: COLMEIA_NOTARY_PROFILE exige COLMEIA_CODESIGN_IDENTITY" >&2
    exit 1
  fi
  xcrun notarytool submit "$APP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

echo "OK: $APP"
