/** @type {import('next').NextConfig} */
const nextConfig = {
  // Static export: the Go server embeds the result (internal/webui/dist)
  // and serves it at / — no Node runtime in production.
  output: 'export',
  // Directory-per-route (predictions/index.html) so Go's file server
  // resolves routes without rewrite rules.
  trailingSlash: true,
};

export default nextConfig;
