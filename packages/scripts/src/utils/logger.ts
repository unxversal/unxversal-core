/* simple logger */
export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

function format(level: LogLevel, message: string): string {
  const ts = new Date().toISOString();
  return ;
}

export const logger = {
  debug: (m: string) => console.debug(format('debug', m)),
  info: (m: string) => console.info(format('info', m)),
  warn: (m: string) => console.warn(format('warn', m)),
  error: (m: string) => console.error(format('error', m)),
};
