import { SuiClient, type SuiEventFilter } from '@mysten/sui/client';
import { SuiTransactionBlockResponse } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { PerpetualsClient } from '../clients/perpetuals';
import { FuturesClient } from '../clients/futures';
import { getCurrentPrice, subscribeToPriceUpdates, SurgeUpdate } from './switchboard';
import { startTrackers, type IndexerTracker } from './indexer';

export type StopLossOrder = {
  id: string;
  marketType: 'perpetuals' | 'futures';
  marketId: string;
  userAddress: string;
  positionType: 'long' | 'short';
  currentQuantity: number;
  triggerPrice: number; // Stop loss trigger price (in 1e6 scale)
  symbol: string; // e.g., "SUI/USD"
  quantityToClose?: number; // Optional partial close; defaults to full position
  isActive: boolean;
  createdAt: number;
  lastChecked: number;
};

export type PositionData = {
  marketType: 'perpetuals' | 'futures';
  marketId: string;
  userAddress: string;
  longQty: number;
  shortQty: number;
  symbol: string;
  lastUpdated: number;
};

export type StopLossConfig = {
  perpsPkgId: string;
  futuresPkgId: string;
  oracleRegistryId: string;
  aggregatorId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  rewardsId: string;
  checkInterval: number; // ms between price checks
  priceThreshold: number; // bps threshold to avoid noise triggers
};

export class StopLossManager {
  private client: SuiClient;
  private config: StopLossConfig;
  private perpClient: PerpetualsClient;
  private futuresClient: FuturesClient;
  private stopLossOrders: Map<string, StopLossOrder> = new Map();
  private positions: Map<string, PositionData> = new Map();
  private isRunning = false;
  private checkInterval?: NodeJS.Timeout;
  private priceSubscription?: () => void;

  constructor(client: SuiClient, config: StopLossConfig) {
    this.client = client;
    this.config = config;
    this.perpClient = new PerpetualsClient(config.perpsPkgId);
    this.futuresClient = new FuturesClient(config.futuresPkgId);
    
    // Load persisted orders from localStorage
    this.loadPersistedOrders();
  }

  // === Core Management ===

  async start(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;

    // Subscribe to price updates
    this.priceSubscription = subscribeToPriceUpdates(this.handlePriceUpdate.bind(this));

    // Start position tracking via event indexing
    await this.startPositionTracking();

    // Start periodic stop loss checks
    this.checkInterval = setInterval(() => {
      this.checkAllStopLossOrders();
    }, this.config.checkInterval);

    console.log('[StopLoss] Manager started');
  }

  async stop(): Promise<void> {
    if (!this.isRunning) return;
    this.isRunning = false;

    if (this.checkInterval) {
      clearInterval(this.checkInterval);
      this.checkInterval = undefined;
    }

    if (this.priceSubscription) {
      this.priceSubscription();
      this.priceSubscription = undefined;
    }

    console.log('[StopLoss] Manager stopped');
  }

  // === Stop Loss Order Management ===

  createStopLossOrder(order: Omit<StopLossOrder, 'id' | 'isActive' | 'createdAt' | 'lastChecked'>): string {
    const id = `${order.marketType}_${order.marketId}_${order.userAddress}_${Date.now()}`;
    const stopLossOrder: StopLossOrder = {
      ...order,
      id,
      isActive: true,
      createdAt: Date.now(),
      lastChecked: Date.now(),
    };

    this.stopLossOrders.set(id, stopLossOrder);
    this.persistOrders();
    
    console.log(`[StopLoss] Created order ${id} for ${order.symbol} at trigger ${order.triggerPrice}`);
    return id;
  }

  cancelStopLossOrder(orderId: string): boolean {
    const order = this.stopLossOrders.get(orderId);
    if (!order) return false;

    order.isActive = false;
    this.stopLossOrders.set(orderId, order);
    this.persistOrders();
    
    console.log(`[StopLoss] Cancelled order ${orderId}`);
    return true;
  }

  getStopLossOrders(userAddress?: string): StopLossOrder[] {
    const orders = Array.from(this.stopLossOrders.values());
    return userAddress 
      ? orders.filter(o => o.userAddress === userAddress && o.isActive)
      : orders.filter(o => o.isActive);
  }

  // === Position Tracking ===

  private async startPositionTracking(): Promise<void> {
    // Track perpetual position events
    const perpEventFilter: SuiEventFilter = {
      Package: this.config.perpsPkgId,
    };

    // Track futures position events  
    const futuresEventFilter: SuiEventFilter = {
      Package: this.config.futuresPkgId,
    };

    const trackers: IndexerTracker[] = [
      {
        id: 'perp_positions_stoploss',
        filter: perpEventFilter,
        pageLimit: 100,
      },
      {
        id: 'futures_positions_stoploss', 
        filter: futuresEventFilter,
        pageLimit: 100,
      },
    ];

    await startTrackers(this.client, trackers);
  }

  private updatePosition(data: PositionData): void {
    const key = `${data.marketType}_${data.marketId}_${data.userAddress}`;
    this.positions.set(key, data);
    
    // Update quantity in related stop loss orders
    for (const [orderId, order] of this.stopLossOrders) {
      if (order.marketId === data.marketId && 
          order.userAddress === data.userAddress && 
          order.marketType === data.marketType) {
        
        const currentQty = order.positionType === 'long' ? data.longQty : data.shortQty;
        const updatedOrder = { ...order, currentQuantity: currentQty };
        this.stopLossOrders.set(orderId, updatedOrder);
      }
    }
  }

  // === Price Monitoring ===

  private handlePriceUpdate(update: SurgeUpdate): void {
    const { symbol, price } = update.data;
    const price1e6 = Math.round(price * 1_000_000);
    
    // Check all stop loss orders for this symbol
    for (const order of this.stopLossOrders.values()) {
      if (order.symbol === symbol && order.isActive) {
        this.checkStopLossOrder(order, price1e6);
      }
    }
  }

  private async checkAllStopLossOrders(): Promise<void> {
    const now = Date.now();
    const promises: Promise<void>[] = [];

    for (const order of this.stopLossOrders.values()) {
      if (!order.isActive) continue;
      if (now - order.lastChecked < this.config.checkInterval) continue;

      promises.push(this.checkStopLossOrderByFetch(order));
    }

    await Promise.allSettled(promises);
  }

  private async checkStopLossOrderByFetch(order: StopLossOrder): Promise<void> {
    try {
      const currentPrice = getCurrentPrice(order.symbol);
      if (currentPrice > 0) {
        const price1e6 = Math.round(currentPrice * 1_000_000);
        this.checkStopLossOrder(order, price1e6);
      }

      // Update last checked time
      order.lastChecked = Date.now();
      this.stopLossOrders.set(order.id, order);
    } catch (error) {
      console.error(`[StopLoss] Error checking order ${order.id}:`, error);
    }
  }

  private checkStopLossOrder(order: StopLossOrder, currentPrice1e6: number): void {
    if (!order.isActive || order.currentQuantity <= 0) return;

    const shouldTrigger = order.positionType === 'long' 
      ? currentPrice1e6 <= order.triggerPrice  // Long: trigger when price drops to/below stop
      : currentPrice1e6 >= order.triggerPrice; // Short: trigger when price rises to/above stop

    if (shouldTrigger) {
      // Add threshold to avoid noise triggers
      const thresholdBps = this.config.priceThreshold;
      const threshold1e6 = Math.round((order.triggerPrice * thresholdBps) / 10000);
      
      const withinThreshold = order.positionType === 'long'
        ? currentPrice1e6 <= (order.triggerPrice - threshold1e6)
        : currentPrice1e6 >= (order.triggerPrice + threshold1e6);

      if (withinThreshold) {
        console.log(`[StopLoss] Triggering order ${order.id} at price ${currentPrice1e6/1e6}`);
        this.executeStopLoss(order, currentPrice1e6).catch(error => {
          console.error(`[StopLoss] Failed to execute stop loss ${order.id}:`, error);
        });
      }
    }
  }

  // === Trade Execution ===

  private async executeStopLoss(order: StopLossOrder, currentPrice1e6: number): Promise<void> {
    try {
      // Deactivate order immediately to prevent double execution
      order.isActive = false;
      this.stopLossOrders.set(order.id, order);
      this.persistOrders();

      const quantityToClose = order.quantityToClose || order.currentQuantity;
      
      const tx = order.marketType === 'perpetuals' 
        ? this.buildPerpStopLossTx(order, quantityToClose)
        : this.buildFuturesStopLossTx(order, quantityToClose);

      // Execute the transaction
      const result = await this.client.signAndExecuteTransaction({
        transaction: tx,
        signer: this.client, // Note: In real implementation, you'd need proper wallet integration
        options: {
          showEffects: true,
          showEvents: true,
        },
      });

      if (result.effects?.status?.status === 'success') {
        console.log(`[StopLoss] Successfully executed stop loss ${order.id}. Tx: ${result.digest}`);
        
        // Emit event for UI updates
        this.emitStopLossEvent('executed', {
          orderId: order.id,
          symbol: order.symbol,
          triggerPrice: order.triggerPrice,
          executionPrice: currentPrice1e6,
          quantity: quantityToClose,
          txDigest: result.digest,
        });
      } else {
        // Reactivate order if execution failed
        order.isActive = true;
        this.stopLossOrders.set(order.id, order);
        this.persistOrders();
        
        console.error(`[StopLoss] Transaction failed for order ${order.id}:`, result.effects?.status);
      }
    } catch (error) {
      // Reactivate order on error
      order.isActive = true;
      this.stopLossOrders.set(order.id, order);
      this.persistOrders();
      
      console.error(`[StopLoss] Error executing stop loss ${order.id}:`, error);
    }
  }

  private buildPerpStopLossTx<Collat extends string>(order: StopLossOrder, quantity: number): Transaction {
    const isClosingLong = order.positionType === 'long';
    
    const args = {
      marketId: order.marketId,
      oracleRegistryId: this.config.oracleRegistryId,
      aggregatorId: this.config.aggregatorId,
      feeConfigId: this.config.feeConfigId,
      feeVaultId: this.config.feeVaultId,
      stakingPoolId: this.config.stakingPoolId,
      rewardsId: this.config.rewardsId,
      qty: BigInt(quantity),
    };

    return isClosingLong 
      ? this.perpClient.closeLong<Collat>(args)
      : this.perpClient.closeShort<Collat>(args);
  }

  private buildFuturesStopLossTx<Collat extends string>(order: StopLossOrder, quantity: number): Transaction {
    const isClosingLong = order.positionType === 'long';
    
    const args = {
      marketId: order.marketId,
      oracleRegistryId: this.config.oracleRegistryId,
      aggregatorId: this.config.aggregatorId,
      feeConfigId: this.config.feeConfigId,
      feeVaultId: this.config.feeVaultId,
      stakingPoolId: this.config.stakingPoolId,
      rewardsId: this.config.rewardsId,
      qty: BigInt(quantity),
    };

    return isClosingLong 
      ? this.futuresClient.closeLong<Collat>(args)
      : this.futuresClient.closeShort<Collat>(args);
  }

  // === Persistence ===

  private persistOrders(): void {
    const ordersData = Array.from(this.stopLossOrders.entries());
    localStorage.setItem('stopLossOrders', JSON.stringify(ordersData));
  }

  private loadPersistedOrders(): void {
    try {
      const stored = localStorage.getItem('stopLossOrders');
      if (stored) {
        const ordersData = JSON.parse(stored) as [string, StopLossOrder][];
        this.stopLossOrders = new Map(ordersData);
        
        // Clean up old inactive orders (older than 7 days)
        const weekAgo = Date.now() - (7 * 24 * 60 * 60 * 1000);
        for (const [id, order] of this.stopLossOrders) {
          if (!order.isActive && order.createdAt < weekAgo) {
            this.stopLossOrders.delete(id);
          }
        }
        this.persistOrders();
      }
    } catch (error) {
      console.error('[StopLoss] Error loading persisted orders:', error);
    }
  }

  // === Events ===

  private eventListeners: Map<string, ((data: any) => void)[]> = new Map();

  addEventListener(event: 'executed' | 'cancelled' | 'created', listener: (data: any) => void): void {
    if (!this.eventListeners.has(event)) {
      this.eventListeners.set(event, []);
    }
    this.eventListeners.get(event)!.push(listener);
  }

  removeEventListener(event: 'executed' | 'cancelled' | 'created', listener: (data: any) => void): void {
    const listeners = this.eventListeners.get(event);
    if (listeners) {
      const index = listeners.indexOf(listener);
      if (index > -1) {
        listeners.splice(index, 1);
      }
    }
  }

  private emitStopLossEvent(event: 'executed' | 'cancelled' | 'created', data: any): void {
    const listeners = this.eventListeners.get(event);
    if (listeners) {
      listeners.forEach(listener => {
        try {
          listener(data);
        } catch (error) {
          console.error(`[StopLoss] Event listener error for ${event}:`, error);
        }
      });
    }
  }

  // === Utility ===

  calculateStopLossPrice(currentPrice: number, percentage: number, isLong: boolean): number {
    // For long positions: stop loss is below current price
    // For short positions: stop loss is above current price
    const multiplier = isLong ? (1 - percentage / 100) : (1 + percentage / 100);
    return Math.round(currentPrice * multiplier * 1_000_000); // Return in 1e6 scale
  }

  getPositionData(marketType: 'perpetuals' | 'futures', marketId: string, userAddress: string): PositionData | undefined {
    const key = `${marketType}_${marketId}_${userAddress}`;
    return this.positions.get(key);
  }
}

// Singleton instance
let stopLossManagerInstance: StopLossManager | null = null;

export function getStopLossManager(client?: SuiClient, config?: StopLossConfig): StopLossManager {
  if (!stopLossManagerInstance && client && config) {
    stopLossManagerInstance = new StopLossManager(client, config);
  }
  
  if (!stopLossManagerInstance) {
    throw new Error('StopLossManager not initialized. Call with client and config first.');
  }
  
  return stopLossManagerInstance;
}

export function initializeStopLossManager(client: SuiClient, config: StopLossConfig): StopLossManager {
  if (stopLossManagerInstance) {
    stopLossManagerInstance.stop();
  }
  stopLossManagerInstance = new StopLossManager(client, config);
  return stopLossManagerInstance;
}
