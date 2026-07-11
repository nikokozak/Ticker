import { defineConfig, Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const outputDirectory = fileURLToPath(new URL('../Sources/Ticker/Resources', import.meta.url));

function cleanWebOutput(): Plugin {
  return {
    name: 'clean-web-output',
    buildStart() {
      rmSync(`${outputDirectory}/assets`, { recursive: true, force: true });
      rmSync(`${outputDirectory}/index.html`, { force: true });
    },
  };
}

// Remove crossorigin attributes from HTML output.
// When loaded via file:// in WKWebView, crossorigin triggers CORS mode
// which fails because file:// has null origin.
function removeCrossorigin(): Plugin {
  return {
    name: 'remove-crossorigin',
    transformIndexHtml(html) {
      return html.replace(/ crossorigin/g, '');
    },
  };
}

export default defineConfig(({ command }) => ({
  plugins: [react(), ...(command === 'build' ? [cleanWebOutput(), removeCrossorigin()] : [])],
  server: {
    port: 6660,
    strictPort: true,
  },
  // Release builds are loaded from a local file URL inside the app bundle, so
  // assets must be referenced relatively (./assets/...) instead of /assets/...
  base: command === 'build' ? './' : '/',
  build: {
    outDir: '../Sources/Ticker/Resources',
    // Preserve bundled native resources (for example Core ML models).
    emptyOutDir: false,
  },
}));
