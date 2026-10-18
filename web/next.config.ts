import type { NextConfig } from 'next';
const nextConfig: NextConfig = {
  images: { remotePatterns: [{ protocol: 'https', hostname: 'img.youtube.com', pathname: '/vi/1h_iX-sqAmE/**' }] },
};
export default nextConfig;
