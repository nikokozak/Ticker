import { defineConfig, Plugin } from 'vite';
import react from '@vitejs/plugin-react';

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
  plugins: [react(), ...(command === 'build' ? [removeCrossorigin()] : [])],
  server: {
    port: 6660,
    strictPort: true,
  },
  // Release builds are loaded from a local file URL inside the app bundle, so
  // assets must be referenced relatively (./assets/...) instead of /assets/...
  base: command === 'build' ? './' : '/',
  build: {
    outDir: '../Sources/Ticker/Resources',
    emptyOutDir: true,
  },
}));
