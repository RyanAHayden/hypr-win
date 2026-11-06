import * as zebar from 'https://esm.sh/zebar@3.0';

/**
 * Zebar provider group configuration
 * Provides data for GlazeWM workspaces, system stats, media, and network
 */
export const providers = zebar.createProviderGroup({
  glazewm: { type: 'glazewm' },
  date: { type: 'date', formatting: 'EEE MMM d h:mm:ss a' },
  cpu: { type: 'cpu' },
  memory: { type: 'memory' },
  battery: { type: 'battery' },
  network: { type: 'network' },
  media: { type: 'media' },
});
