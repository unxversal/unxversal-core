import { StrictMode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createRoot } from 'react-dom/client'
import '@mysten/dapp-kit/dist/index.css'
import './index.css'
import App from './App.tsx'
import { initSurgeFromSettings } from './lib/switchboard'

const queryClient = new QueryClient()

// Initialize Switchboard Surge streaming from user client-side settings (localStorage)
void initSurgeFromSettings().catch(() => {})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </StrictMode>,
)
