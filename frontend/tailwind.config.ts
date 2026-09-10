import type { Config } from 'tailwindcss'

export default {
  darkMode: ['class', '[data-kb-theme="dark"]'],
  content: ['./index.html', './src/**/*.{ts,tsx}'],
} satisfies Config
