import type { Config } from "tailwindcss";

const config: Config = {
  darkMode: ["class"],
  content: [
    "./app/**/*.{ts,tsx}",
    "./src/**/*.{ts,tsx}"
  ],
  theme: {
    extend: {
      screens: {
        "xs": "360px",
        "sm": "390px",
        "md": "768px",
        "lg": "1024px",
        "xl": "1440px"
      },
      borderRadius: {
        "xl": "14px"
      },
      colors: {
        bg: "hsl(var(--bg))",
        surface: "hsl(var(--surface))",
        card: "hsl(var(--card))",
        muted: "hsl(var(--muted))",
        text: "hsl(var(--text))",
        text2: "hsl(var(--text2))",
        border: "hsl(var(--border))",
        primary: "hsl(var(--primary))",
        primary2: "hsl(var(--primary2))",
        accent: "hsl(var(--accent))",
        accent2: "hsl(var(--accent2))",
        good: "hsl(var(--good))",
        warn: "hsl(var(--warn))",
        bad: "hsl(var(--bad))"
      },
      fontFamily: {
        sans: ["var(--font-sans)", "Segoe UI", "sans-serif"],
        display: ["var(--font-display)", "Times New Roman", "serif"]
      },
      boxShadow: {
        soft: "0 12px 28px hsl(35 40% 22% / 0.08)",
        card: "0 1px 1px hsl(35 28% 22% / 0.04), 0 14px 30px hsl(35 28% 22% / 0.08)"
      }
    }
  },
  plugins: []
};

export default config;
