import vue from '@vitejs/plugin-vue'
import { VitePWA } from 'vite-plugin-pwa'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [
    vue(),
    VitePWA({
      registerType: 'prompt',
      manifest: {
        name: 'Benta Business Control',
        short_name: 'Benta',
        theme_color: '#1a3d32',
        background_color: '#f5f6f0',
        display: 'standalone',
      },
      workbox: { globPatterns: ['**/*.{js,css,html,svg,png,ico}'] },
    }),
  ],
})
