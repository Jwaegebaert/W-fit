// Regenerates W-fit brand SVGs + launcher/splash raster sources.
// Usage (from any dir with @resvg/resvg-js installed, e.g. %TEMP%\wfit-tools):
//   node <repo>\app\assets\brand\source\generate_brand.js [previewDir]
// Then: cd app; dart run flutter_launcher_icons -f flutter_launcher_icons.yaml
//       dart run flutter_native_splash:create --path=flutter_native_splash.yaml
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Resvg } = require(require.resolve('@resvg/resvg-js', {
  paths: [process.cwd(), path.join(os.tmpdir(), 'wfit-tools')],
}));

// Keep in sync with BrandMark in lib/widgets/brand.dart.
const STROKE = 8;
const A = [9, 22], B = [20.5, 48], C = [32, 30], D = [43.5, 48], E = [55, 16];
const pts = (...p) => p.map(([x, y]) => `${x},${y}`).join(' ');

const COLORS = {
  teal: '#0E9F8A',
  deep: '#0A7363',
  bright: '#14B89F',
  ink: '#0E1513',
  mist: '#F6FAF8',
  white: '#FFFFFF',
  mint: '#B3EDE1',
};

const line = (points, color) =>
  `<polyline points="${points}" fill="none" stroke="${color}" stroke-width="${STROKE}" stroke-linecap="round" stroke-linejoin="round"/>`;

// Two rising strokes: first V in deep teal, the second (steeper, higher) in bright teal.
// Split vertically through the middle peak so the fold reads as a clean seam.
let clipId = 0;
const markBody = (c1, c2) => {
  const id = `wfit-left-${clipId++}`;
  return `<defs><clipPath id="${id}"><rect x="0" y="0" width="${C[0]}" height="64"/></clipPath></defs>` +
    line(pts(A, B, C, D, E), c2) + `<g clip-path="url(#${id})">${line(pts(A, B, C, D, E), c1)}</g>`;
};
const monoBody = (c) => line(pts(A, B, C, D, E), c);

const svg = (body, size = 64, view = '0 0 64 64', bg = '') =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="${view}">${bg}${body}</svg>\n`;

// Places the 64-unit mark into a square canvas of `canvas` units, scaled so the mark is `markFrac` of the canvas.
const placed = (body, canvas, markFrac) => {
  const s = (canvas * markFrac) / 64;
  const o = (canvas - 64 * s) / 2;
  return `<g transform="translate(${o} ${o}) scale(${s})">${body}</g>`;
};

const render = (svgText, width) =>
  new Resvg(svgText, { fitTo: { mode: 'width', value: width }, background: 'rgba(0,0,0,0)' }).render().asPng();

const brandDir = path.resolve(__dirname, '..');
const srcDir = __dirname;

const logo = svg(markBody(COLORS.deep, COLORS.bright));
const logoMono = svg(monoBody('#000000'));
fs.writeFileSync(path.join(brandDir, 'logo.svg'), logo);
fs.writeFileSync(path.join(brandDir, 'logo_mono.svg'), logoMono);

const N = 1024;
const write = (name, text, px = N) => fs.writeFileSync(path.join(srcDir, name), render(text, px));

// Adaptive foreground: 108dp canvas, 66dp safe circle -> mark spans ~56% of the canvas.
write('icon_foreground.png', svg(placed(markBody(COLORS.mint, COLORS.white), N, 0.56), N, `0 0 ${N} ${N}`));
write('icon_monochrome.png', svg(placed(monoBody(COLORS.white), N, 0.56), N, `0 0 ${N} ${N}`));
// Legacy (<API 26): rounded square, brand background, white mark.
write('icon_legacy.png', svg(
  placed(markBody(COLORS.mint, COLORS.white), N, 0.62), N, `0 0 ${N} ${N}`,
  `<rect x="40" y="40" width="${N - 80}" height="${N - 80}" rx="${N * 0.22}" fill="${COLORS.teal}"/>`,
));
// Pre-Android 12 splash (treated as xxxhdpi -> 160dp box): two-tone mark on light / brighter tones on dark.
write('splash_light.png', svg(placed(markBody(COLORS.deep, COLORS.bright), N, 0.85), N, `0 0 ${N} ${N}`), 640);
write('splash_dark.png', svg(placed(markBody('#3CC7AE', '#7FE6D2'), N, 0.85), N, `0 0 ${N} ${N}`), 640);
// Android 12+: same proportions as the adaptive icon (visible circle = 2/3 of the canvas).
write('splash_android12.png', svg(placed(markBody(COLORS.mint, COLORS.white), N, 0.56), N, `0 0 ${N} ${N}`), 1152);

const previewDir = process.argv[2];
if (previewDir) {
  fs.mkdirSync(previewDir, { recursive: true });
  const cell = (x, y, size, body, bg) =>
    `<rect x="${x}" y="${y}" width="${size}" height="${size}" fill="${bg}"/>` +
    `<svg x="${x}" y="${y}" width="${size}" height="${size}" viewBox="0 0 64 64">${body}</svg>`;
  const rows = [
    [markBody(COLORS.deep, COLORS.bright), COLORS.mist],
    [markBody('#3CC7AE', '#7FE6D2'), COLORS.ink],
    [markBody(COLORS.mint, COLORS.white), COLORS.teal],
    [monoBody('#000000'), COLORS.white],
  ];
  let body = '';
  rows.forEach(([b, bg], r) => {
    let x = 0;
    for (const s of [24, 32, 48, 96, 160]) {
      body += cell(x, r * 170, s, b, bg);
      x += s + 10;
    }
  });
  fs.writeFileSync(path.join(previewDir, 'preview.png'), render(svg(body, 420, '0 0 420 680'), 420));
  // Adaptive icon simulation: circle mask over background + foreground.
  const fg = fs.readFileSync(path.join(srcDir, 'icon_foreground.png')).toString('base64');
  const sim = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="512" height="512" viewBox="0 0 108 108">` +
    `<clipPath id="c"><circle cx="54" cy="54" r="36"/></clipPath><g clip-path="url(#c)"><rect width="108" height="108" fill="${COLORS.teal}"/>` +
    `<image width="108" height="108" xlink:href="data:image/png;base64,${fg}"/></g><circle cx="54" cy="54" r="33" fill="none" stroke="red" stroke-width="0.3"/></svg>`;
  fs.writeFileSync(path.join(previewDir, 'adaptive_sim.png'), render(sim, 512));
}
console.log('brand assets generated');
