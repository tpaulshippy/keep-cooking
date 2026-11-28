import { defineConfig } from 'vite';

export default defineConfig({
  base: '/app/',
  build: { outDir: 'dist' },
  server: { port: 5174 },
  preview: { port: 5174 },
});
