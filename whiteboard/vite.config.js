import { defineConfig } from 'vite';
export default defineConfig({
  base: '/whiteboard/',
  define: { 'process.env.IS_PREACT': 'false' },
  build: { chunkSizeWarningLimit: 4000 },
});
