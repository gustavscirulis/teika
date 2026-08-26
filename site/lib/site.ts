export const APP_STORE_URL = 'https://apps.apple.com/app/id6796609245';
export const SOURCE_URL = 'https://github.com/gustavscirulis/teika';

/** True if APP_STORE_URL is changed back to the pre-launch placeholder. */
export const APP_STORE_URL_IS_PLACEHOLDER = APP_STORE_URL.includes('id0000000000');

export const CONTACT_EMAIL = 'gustavs.cirulis@gmail.com';

/** Verified against the model card and the Open ASR Leaderboard, August 2026. */
export const MODEL = {
  name: 'Parakeet TDT 0.6B v3',
  vendor: 'NVIDIA',
  build: 'FluidInference/parakeet-tdt-0.6b-v3-coreml',
  cardUrl: 'https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3',
  languages: 25,
  downloadSize: '0.5 GB',
} as const;
