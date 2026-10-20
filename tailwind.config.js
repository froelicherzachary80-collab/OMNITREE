/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        navy: { 950: '#070d1c', 900: '#0b1428', 800: '#122040', 700: '#1b2d55' },
        emerald: { 400: '#34d399', 500: '#10b981', 600: '#059669' },
        gold: { 300: '#f2d58a', 400: '#e5c062', 500: '#c9a227' },
      },
      fontFamily: { serif: ['Georgia', 'Cambria', 'serif'] },
    },
  },
  plugins: [],
};
