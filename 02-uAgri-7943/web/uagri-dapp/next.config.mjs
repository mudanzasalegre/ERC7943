import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  typedRoutes: true,
  /**
   * Fix for MetaMask SDK (pulled in by wagmi MetaMask connector export path)
   * which references React Native AsyncStorage.
   * In Next/Web builds we alias it to a tiny web-safe shim.
   */
  webpack: (config) => {
    config.resolve = config.resolve || {};
    const asyncStorageShim = path.join(__dirname, "src/shims/asyncStorage.ts");
    config.resolve.alias = {
      ...(config.resolve.alias || {}),
      "@react-native-async-storage/async-storage": asyncStorageShim,
      "@react-native-async-storage/async-storage$": asyncStorageShim,
      "@react-native-async-storage/async-storage/lib/commonjs/index.js": asyncStorageShim,
      "@react-native-async-storage/async-storage/lib/module/index.js": asyncStorageShim,
      "react-native$": false
    };
    return config;
  }
};

export default nextConfig;
