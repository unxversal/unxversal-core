import { SuiClient, type SuiEventFilter } from '@mysten/sui/client';
import { startTrackers, type IndexerTracker } from './indexer';
import { db } from './storage';

export type PositionUpdate = {
  marketType: 'perpetuals' | 'futures';
  marketId: string;
  userAddress: string;
  longQty: number;
  shortQty: number;
  symbol: string;
  timestamp: number;
  txDigest: string;
};

export type PositionChangeCallback = (update: PositionUpdate) => void;

export class PositionTracker {
  private client: SuiClient;
  private packageIds: { perpetuals: string; futures: string };
  private subscribers: Set<PositionChangeCallback> = new Set();
  private isRunning = false;

  constructor(client: SuiClient, packageIds: { perpetuals: string; futures: string }) {
    this.client = client;
    this.packageIds = packageIds;
  }

  async start(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;

    // Set up event filters for position-changing events
    const perpEventFilter: SuiEventFilter = {
      Package: this.packageIds.perpetuals,
    };

    const futuresEventFilter: SuiEventFilter = {
      Package: this.packageIds.futures,
    };

    const trackers: IndexerTracker[] = [
      {
        id: 'perp_positions_tracker',
        filter: perpEventFilter,
        pageLimit: 100,
      },
      {
        id: 'futures_positions_tracker',
        filter: futuresEventFilter,
        pageLimit: 100,
      },
    ];

    // Start the indexer trackers
    await startTrackers(this.client, trackers);

    // Set up periodic checking for new events
    this.startEventProcessing();

    console.log('[PositionTracker] Started monitoring position changes');
  }

  stop(): void {
    this.isRunning = false;
    console.log('[PositionTracker] Stopped monitoring position changes');
  }

  subscribe(callback: PositionChangeCallback): () => void {
    this.subscribers.add(callback);
    
    return () => {
      this.subscribers.delete(callback);
    };
  }

  private startEventProcessing(): void {
    const processEvents = async () => {
      if (!this.isRunning) return;

      try {
        // Query recent events from our indexed data
        const recentEvents = await this.getRecentPositionEvents();
        
        for (const event of recentEvents) {
          const positionUpdate = this.parseEventToPositionUpdate(event);
          if (positionUpdate) {
            this.notifySubscribers(positionUpdate);
          }
        }
      } catch (error) {
        console.error('[PositionTracker] Error processing events:', error);
      }

      // Schedule next processing
      if (this.isRunning) {
        setTimeout(processEvents, 5000); // Check every 5 seconds
      }
    };

    // Start processing
    processEvents();
  }

  private async getRecentPositionEvents(): Promise<any[]> {
    // Query the indexed events from the last 1 minute
    const oneMinuteAgo = Date.now() - 60_000;
    
    const events = await db.events
      .where('tsMs')
      .above(oneMinuteAgo)
      .and(event => 
        event.packageId === this.packageIds.perpetuals ||
        event.packageId === this.packageIds.futures
      )
      .and(event => 
        // Filter for position-changing events
        event.type?.includes('PositionChanged') ||
        event.type?.includes('CollateralDeposited') ||
        event.type?.includes('CollateralWithdrawn') ||
        event.type?.includes('Liquidated')
      )
      .toArray();

    return events;
  }

  private parseEventToPositionUpdate(event: any): PositionUpdate | null {
    try {
      const parsedJson = event.parsedJson;
      if (!parsedJson) return null;

      // Extract common fields
      const marketId = parsedJson.market_id;
      const userAddress = parsedJson.who;
      const timestamp = event.tsMs || Date.now();
      const txDigest = event.txDigest;

      if (!marketId || !userAddress) return null;

      // Determine market type
      const marketType: 'perpetuals' | 'futures' = event.packageId === this.packageIds.perpetuals 
        ? 'perpetuals' 
        : 'futures';

      // For position changed events, we can extract position data
      if (event.type?.includes('PositionChanged')) {
        return {
          marketType,
          marketId,
          userAddress,
          longQty: parsedJson.new_long || 0,
          shortQty: parsedJson.new_short || 0,
          symbol: this.extractSymbolFromEvent(event),
          timestamp,
          txDigest,
        };
      }

      // For other events, we need to query the current position state
      // This would require additional on-chain queries
      return {
        marketType,
        marketId,
        userAddress,
        longQty: 0, // Would need to query current state
        shortQty: 0, // Would need to query current state  
        symbol: this.extractSymbolFromEvent(event),
        timestamp,
        txDigest,
      };
    } catch (error) {
      console.error('[PositionTracker] Error parsing event:', error);
      return null;
    }
  }

  private extractSymbolFromEvent(event: any): string {
    // Try to extract symbol from event data
    // This depends on how the events are structured
    const parsedJson = event.parsedJson;
    
    // Common ways symbols might be stored
    if (parsedJson?.symbol) return parsedJson.symbol;
    if (parsedJson?.market_symbol) return parsedJson.market_symbol;
    
    // Fallback to extracting from market ID or other data
    return 'UNKNOWN';
  }

  private notifySubscribers(update: PositionUpdate): void {
    this.subscribers.forEach(callback => {
      try {
        callback(update);
      } catch (error) {
        console.error('[PositionTracker] Error in position update callback:', error);
      }
    });
  }

  // Static helper for querying current position state
  static async getCurrentPosition(
    client: SuiClient,
    marketType: 'perpetuals' | 'futures',
    marketId: string,
    userAddress: string
  ): Promise<{ longQty: number; shortQty: number; symbol: string } | null> {
    try {
      // This would need to be implemented based on your specific market structure
      // For now, returning null as a placeholder
      
      // Example query structure:
      // const result = await client.getDynamicFieldObject({
      //   parentId: marketId,
      //   name: {
      //     type: 'address',
      //     value: userAddress,
      //   },
      // });
      
      return null;
    } catch (error) {
      console.error('[PositionTracker] Error querying current position:', error);
      return null;
    }
  }
}

// Singleton instance
let positionTrackerInstance: PositionTracker | null = null;

export function getPositionTracker(
  client?: SuiClient,
  packageIds?: { perpetuals: string; futures: string }
): PositionTracker {
  if (!positionTrackerInstance && client && packageIds) {
    positionTrackerInstance = new PositionTracker(client, packageIds);
  }
  
  if (!positionTrackerInstance) {
    throw new Error('PositionTracker not initialized. Call with client and packageIds first.');
  }
  
  return positionTrackerInstance;
}

export function initializePositionTracker(
  client: SuiClient,
  packageIds: { perpetuals: string; futures: string }
): PositionTracker {
  if (positionTrackerInstance) {
    positionTrackerInstance.stop();
  }
  positionTrackerInstance = new PositionTracker(client, packageIds);
  return positionTrackerInstance;
}
