import Foundation

extension MessageDocument {
    /// Adapts HTML mail to dark mode. The web view runs it in Tern's own script
    /// world, so page JavaScript stays off.
    ///
    /// It works from each element's computed colors, so stylesheets, inline
    /// styles, `bgcolor` and `<font color>` all count. Light backgrounds turn
    /// dark in OKLab, keeping their hue, and white lands on the system canvas.
    /// Saturated mid tones such as buttons keep their color. Text keeps its
    /// color while it has 4.5:1 contrast with its new background and otherwise
    /// moves toward that contrast. Translucency can limit the result. Image
    /// pixels are left alone; non-RGB colors and image backgrounds are not mapped.
    ///
    /// The page itself stays white, so mail shows as designed if this can't
    /// run. An appearance change restores the original inline styles before
    /// adapting again. Evaluated without a DOM, it returns the color mapping.
    public static let darkModeScript = #"""
        (() => {
          // sRGB to OKLab and back, with the matrices from Björn Ottosson's reference.
          const toLinear = c => (c /= 255) <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
          const fromLinear = c => Math.round(255 * Math.min(1, Math.max(0,
            c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055)));
          const oklab = rgb => {
            const [r, g, b] = rgb.map(toLinear);
            const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
            const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
            const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
            return [
              0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
              1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
              0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
            ];
          };
          const fromOklab = ([L, A, B]) => {
            const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3;
            const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3;
            const s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3;
            return [
              4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
              -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
              -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
            ].map(fromLinear);
          };
          const chroma = ([, A, B]) => Math.hypot(A, B);
          const luminance = rgb => {
            const [r, g, b] = rgb.map(toLinear);
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
          };
          const contrast = (x, y) => {
            const [high, low] = [luminance(x), luminance(y)].sort((p, q) => q - p);
            return (high + 0.05) / (low + 0.05);
          };
          const blend = (rgb, alpha, under) => rgb.map((c, i) => Math.round(c * alpha + under[i] * (1 - alpha)));
          const same = (x, y) => x.every((c, i) => c === y[i]);

          // White maps to the canvas and black to the default text color.
          const palette = (canvas, text) => {
            const darkest = oklab(canvas)[0];
            const lightest = oklab(text)[0];
            const flip = L => lightest - (lightest - darkest) * L;
            const withLightness = (rgb, L) => {
              const [from, A, B] = oklab(rgb);
              // Darker colors hold less chroma, so it shrinks with the lightness.
              const scale = from > 0 ? Math.min(1, L / from) : 1;
              return fromOklab([L, A * scale, B * scale]);
            };
            return {
              background(rgb) {
                const lab = oklab(rgb);
                const light = lab[0] > 0.85 || (lab[0] > 0.6 && chroma(lab) < 0.1);
                return light ? withLightness(rgb, flip(lab[0])) : rgb;
              },
              // Neutral rules and borders flip either way, so dividers keep their weight.
              line(rgb) {
                const lab = oklab(rgb);
                return lab[0] > 0.85 || chroma(lab) < 0.1 ? withLightness(rgb, flip(lab[0])) : rgb;
              },
              text(rgb, alpha, background) {
                const readable = color => contrast(blend(color, alpha, background), background) >= 4.5;
                if (readable(rgb)) return rgb;
                const from = oklab(rgb)[0];
                const step = oklab(background)[0] < 0.6 ? 0.02 : -0.02;
                let target = step > 0 ? Math.max(from, flip(from)) : from;
                let color = withLightness(rgb, target);
                while (!readable(color) && target > 0 && target < 1) {
                  target = Math.min(1, Math.max(0, target + step));
                  color = withLightness(rgb, target);
                }
                return color;
              },
              contrast,
            };
          };
          if (typeof document === 'undefined') return palette;

          const scheme = matchMedia('(prefers-color-scheme: dark)');
          const sides = ['top', 'right', 'bottom', 'left'];
          // Each adapted element's style attribute as the sender wrote it.
          const saved = new Map();
          const parse = value => {
            const match = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)\s*(?:[,/]\s*([\d.]+)\s*)?\)$/.exec(value);
            return match && { rgb: match.slice(1, 4).map(Number), alpha: match[4] === undefined ? 1 : Number(match[4]) };
          };
          const format = (rgb, alpha) => alpha < 1 ? `rgba(${rgb.join(', ')}, ${alpha})` : `rgb(${rgb.join(', ')})`;
          const systemColors = () => {
            const probe = document.createElement('span');
            probe.style.cssText = 'color-scheme: dark; background-color: Canvas; color: CanvasText; display: none';
            document.documentElement.append(probe);
            const style = getComputedStyle(probe);
            const colors = [parse(style.backgroundColor), parse(style.color)];
            probe.remove();
            return colors;
          };

          const adapt = () => {
            const [canvas, text] = systemColors();
            if (!canvas || !text) return;
            const colors = palette(canvas.rgb, text.rgb);
            const root = document.documentElement;
            const elements = document.body ? [root, document.body, ...document.body.querySelectorAll('*')] : [root];
            // Read every style before writing any, so a write can't skew a later read.
            const reads = elements.map(element => {
              const style = getComputedStyle(element);
              return {
                color: parse(style.color),
                background: parse(style.backgroundColor),
                image: style.backgroundImage,
                borders: sides.map(side => style.getPropertyValue(`border-${side}-style`) === 'none'
                  ? null : parse(style.getPropertyValue(`border-${side}-color`))),
              };
            });
            const writes = [[root, 'color-scheme', 'dark']];
            const resolved = new Map();
            elements.forEach((element, index) => {
              const read = reads[index];
              const parent = resolved.get(element.parentElement) ?? { background: canvas.rgb, colorChanged: false };
              let background = parent.background;
              if (read.background && read.background.alpha > 0) {
                const { rgb, alpha } = read.background;
                const adapted = colors.background(rgb);
                background = blend(adapted, alpha, parent.background);
                if (!same(adapted, rgb)) writes.push([element, 'background-color', format(adapted, alpha)]);
              }
              if (read.image.includes('gradient(')) {
                let first = null;
                const image = read.image.replace(/rgba?\([^)]*\)/g, value => {
                  const color = parse(value);
                  if (!color) return value;
                  const adapted = colors.background(color.rgb);
                  first ??= blend(adapted, color.alpha, background);
                  return format(adapted, color.alpha);
                });
                if (first) background = first;
                writes.push([element, 'background-image', image]);
              }
              let colorChanged = false;
              if (read.color) {
                const { rgb, alpha } = read.color;
                const adapted = colors.text(rgb, alpha, background);
                colorChanged = !same(adapted, rgb);
                // A kept color still needs writing when the parent's changed, or it would inherit the new one.
                if (colorChanged || parent.colorChanged) writes.push([element, 'color', format(adapted, alpha)]);
              }
              read.borders.forEach((border, side) => {
                if (!border || border.alpha === 0) return;
                const adapted = colors.line(border.rgb);
                if (!same(adapted, border.rgb)) writes.push([element, `border-${sides[side]}-color`, format(adapted, border.alpha)]);
              });
              resolved.set(element, { background, colorChanged });
            });
            for (const [element, property, value] of writes) {
              if (!saved.has(element)) saved.set(element, element.getAttribute('style'));
              element.style.setProperty(property, value, 'important');
            }
          };

          const restore = () => {
            for (const [element, style] of saved) {
              if (style === null) element.removeAttribute('style');
              else element.setAttribute('style', style);
            }
            saved.clear();
          };
          const update = () => {
            restore();
            if (!scheme.matches) return;
            try {
              adapt();
            } catch {
              // Restore sender styling if adaptation fails.
              restore();
            }
          };
          scheme.addEventListener('change', update);
          update();
          return palette;
        })()
        """#
}
