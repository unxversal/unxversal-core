import { StrictMode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createRoot } from 'react-dom/client'
import '@mysten/dapp-kit/dist/index.css'
import './index.css'
import App from './App.tsx'
import { SuiClientProvider, WalletProvider, makeDappNetworks } from './lib/wallet'

const queryClient = new QueryClient()
const { networkConfig } = makeDappNetworks()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <SuiClientProvider networks={networkConfig} network="testnet">
        <WalletProvider>
          <App />
        </WalletProvider>
      </SuiClientProvider>
    </QueryClientProvider>
  </StrictMode>,
)
