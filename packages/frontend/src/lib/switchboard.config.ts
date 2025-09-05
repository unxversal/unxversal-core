// Central Switchboard (Surge) config
// Set your defaults here so there is a single place to see required settings.
// API key can be left empty to indicate it should be entered by the user at runtime
// (we still allow localStorage overrides at runtime).

export type SwitchboardConfig = {
  apiKey?: string;         // leave undefined/empty to require user input
  symbols: string[];       // default feed symbols to subscribe to
};

export const SWITCHBOARD_CONFIG: SwitchboardConfig = {
  apiKey: '',
  symbols: ['SUI/USD'],
};


