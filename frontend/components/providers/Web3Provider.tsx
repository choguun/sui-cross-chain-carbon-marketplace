'use client'; // This component needs to be a client component

import React, { useState } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { networkConfig } from '@/lib/networkConfig';
import { SuiClientProvider, WalletProvider } from "@mysten/dapp-kit";


interface Web3ProviderProps {
  children: React.ReactNode;
}

export function Web3Provider({ children }: Web3ProviderProps) {
  // Use state to ensure QueryClient is only created once per component instance
  const [queryClient] = useState(() => new QueryClient());

  return (
      <QueryClientProvider client={queryClient}>
        <SuiClientProvider networks={networkConfig} defaultNetwork="testnet">
          <WalletProvider autoConnect>
            {children}
          </WalletProvider>
        </SuiClientProvider>
      </QueryClientProvider>
  );
} 