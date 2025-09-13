import { useState, useEffect, useCallback } from 'react';
import { SuiClient } from '@mysten/sui/client';
import { initializeStopLossManager, getStopLossManager, type StopLossOrder, type StopLossConfig, type PositionData } from '../lib/stopLossManager';

interface UseStopLossOptions {
  client?: SuiClient;
  config?: StopLossConfig;
  userAddress?: string | null;
  autoStart?: boolean;
}

interface UseStopLossReturn {
  isInitialized: boolean;
  isRunning: boolean;
  orders: StopLossOrder[];
  positions: Map<string, PositionData>;
  error: string | null;
  createStopLoss: (order: Omit<StopLossOrder, 'id' | 'isActive' | 'createdAt' | 'lastChecked'>) => Promise<string>;
  cancelStopLoss: (orderId: string) => Promise<boolean>;
  startManager: () => Promise<void>;
  stopManager: () => Promise<void>;
  refreshOrders: () => void;
  clearError: () => void;
}

export function useStopLoss(options: UseStopLossOptions = {}): UseStopLossReturn {
  const { client, config, userAddress, autoStart = true } = options;
  
  const [isInitialized, setIsInitialized] = useState(false);
  const [isRunning, setIsRunning] = useState(false);
  const [orders, setOrders] = useState<StopLossOrder[]>([]);
  const [positions] = useState<Map<string, PositionData>>(new Map());
  const [error, setError] = useState<string | null>(null);

  // Initialize the manager
  useEffect(() => {
    if (!client || !config) {
      setIsInitialized(false);
      return;
    }

    try {
      const manager = initializeStopLossManager(client, config);
      
      // Set up event listeners
      const handleStopLossExecuted = (data: any) => {
        console.log('[StopLoss] Order executed:', data);
        refreshOrders();
      };

      const handleStopLossCreated = (data: any) => {
        console.log('[StopLoss] Order created:', data);
        refreshOrders();
      };

      const handleStopLossCancelled = (data: any) => {
        console.log('[StopLoss] Order cancelled:', data);
        refreshOrders();
      };

      manager.addEventListener('executed', handleStopLossExecuted);
      manager.addEventListener('created', handleStopLossCreated);
      manager.addEventListener('cancelled', handleStopLossCancelled);

      setIsInitialized(true);
      setError(null);

      // Auto-start if requested
      if (autoStart) {
        manager.start().then(() => {
          setIsRunning(true);
        }).catch((err) => {
          setError(`Failed to start stop loss manager: ${err.message}`);
        });
      }

      // Cleanup function
      return () => {
        manager.removeEventListener('executed', handleStopLossExecuted);
        manager.removeEventListener('created', handleStopLossCreated);
        manager.removeEventListener('cancelled', handleStopLossCancelled);
        
        manager.stop().catch(console.error);
        setIsRunning(false);
      };
    } catch (err) {
      setError(`Failed to initialize stop loss manager: ${err instanceof Error ? err.message : 'Unknown error'}`);
      setIsInitialized(false);
    }
  }, [client, config, autoStart]);

  // Refresh orders when user changes
  const refreshOrders = useCallback(() => {
    if (!isInitialized) return;

    try {
      const manager = getStopLossManager();
      const userOrders = manager.getStopLossOrders(userAddress || undefined);
      setOrders(userOrders);
    } catch (err) {
      setError(`Failed to load orders: ${err instanceof Error ? err.message : 'Unknown error'}`);
    }
  }, [isInitialized, userAddress]);

  useEffect(() => {
    refreshOrders();
  }, [refreshOrders]);

  // Create stop loss order
  const createStopLoss = useCallback(async (order: Omit<StopLossOrder, 'id' | 'isActive' | 'createdAt' | 'lastChecked'>): Promise<string> => {
    if (!isInitialized) {
      throw new Error('Stop loss manager not initialized');
    }

    try {
      const manager = getStopLossManager();
      const orderId = manager.createStopLossOrder(order);
      refreshOrders();
      return orderId;
    } catch (err) {
      const errorMsg = `Failed to create stop loss order: ${err instanceof Error ? err.message : 'Unknown error'}`;
      setError(errorMsg);
      throw new Error(errorMsg);
    }
  }, [isInitialized, refreshOrders]);

  // Cancel stop loss order
  const cancelStopLoss = useCallback(async (orderId: string): Promise<boolean> => {
    if (!isInitialized) {
      throw new Error('Stop loss manager not initialized');
    }

    try {
      const manager = getStopLossManager();
      const success = manager.cancelStopLossOrder(orderId);
      if (success) {
        refreshOrders();
      }
      return success;
    } catch (err) {
      const errorMsg = `Failed to cancel stop loss order: ${err instanceof Error ? err.message : 'Unknown error'}`;
      setError(errorMsg);
      throw new Error(errorMsg);
    }
  }, [isInitialized, refreshOrders]);

  // Start manager
  const startManager = useCallback(async (): Promise<void> => {
    if (!isInitialized) {
      throw new Error('Stop loss manager not initialized');
    }

    try {
      const manager = getStopLossManager();
      await manager.start();
      setIsRunning(true);
      setError(null);
    } catch (err) {
      const errorMsg = `Failed to start stop loss manager: ${err instanceof Error ? err.message : 'Unknown error'}`;
      setError(errorMsg);
      throw new Error(errorMsg);
    }
  }, [isInitialized]);

  // Stop manager
  const stopManager = useCallback(async (): Promise<void> => {
    if (!isInitialized) {
      return;
    }

    try {
      const manager = getStopLossManager();
      await manager.stop();
      setIsRunning(false);
    } catch (err) {
      const errorMsg = `Failed to stop stop loss manager: ${err instanceof Error ? err.message : 'Unknown error'}`;
      setError(errorMsg);
    }
  }, [isInitialized]);

  // Clear error
  const clearError = useCallback(() => {
    setError(null);
  }, []);

  return {
    isInitialized,
    isRunning,
    orders,
    positions,
    error,
    createStopLoss,
    cancelStopLoss,
    startManager,
    stopManager,
    refreshOrders,
    clearError,
  };
}

// Utility hooks for common use cases

export function useStopLossForMarket(
  marketType: 'perpetuals' | 'futures',
  marketId: string,
  userAddress?: string | null
) {
  const stopLoss = useStopLoss();
  
  const marketOrders = stopLoss.orders.filter(
    order => order.marketType === marketType && 
             order.marketId === marketId &&
             (!userAddress || order.userAddress === userAddress)
  );

  return {
    ...stopLoss,
    marketOrders,
  };
}

export function useStopLossStatus() {
  const [status, setStatus] = useState<'initializing' | 'running' | 'stopped' | 'error'>('stopped');
  const [lastActivity, setLastActivity] = useState<Date | null>(null);
  
  useEffect(() => {
    try {
      const manager = getStopLossManager();
      
      const handleActivity = () => {
        setLastActivity(new Date());
        setStatus('running');
      };

      manager.addEventListener('executed', handleActivity);
      manager.addEventListener('created', handleActivity);
      manager.addEventListener('cancelled', handleActivity);

      // Check if manager is running
      setStatus('running'); // Assuming it's running if we can get the instance

      return () => {
        manager.removeEventListener('executed', handleActivity);
        manager.removeEventListener('created', handleActivity);
        manager.removeEventListener('cancelled', handleActivity);
      };
    } catch (err) {
      setStatus('error');
    }
  }, []);

  return {
    status,
    lastActivity,
    isActive: status === 'running',
  };
}
