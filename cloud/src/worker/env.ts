export interface Bindings {
  DB: D1Database;
  PRIVATE: R2Bucket;
  ASSETS: Fetcher;
  EMAIL?: SendEmail;
  EMAIL_FROM?: string;
  EMAIL_FROM_NAME?: string;
  /** comma-separated; these users are always admin */
  ADMIN_EMAILS?: string;
  /** e.g. `lifenz.cloudflareaccess.com`; with ACCESS_AUD enables JWT verification */
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUD?: string;
  /** local dev only: acts as this signed-in user when Access isn't configured */
  DEV_USER_EMAIL?: string;
  /** "1" = log emails instead of sending */
  EMAIL_DRY_RUN?: string;
}

/** operator = a PA who can also run the CG Macs' control GUI with their LIFE sign-in */
export type Role = 'pa' | 'operator' | 'production' | 'admin';

export interface User {
  email: string;
  name: string | null;
  role: Role;
}

export interface Device {
  id: string;
  name: string;
  campus_id: string;
}

export type AppEnv = { Bindings: Bindings; Variables: { user: User; device: Device } };
