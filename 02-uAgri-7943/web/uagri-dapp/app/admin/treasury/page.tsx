"use client";

import * as React from "react";
import { PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Badge } from "@/components/ui/Badge";
import { treasuryAbi } from "@/lib/abi";
import { useTx } from "@/hooks/useTx";
import { useAccount, usePublicClient } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { parseUnits } from "viem";

export default function AdminTreasuryPage() {
  const { isConnected } = useAccount();
  const client = usePublicClient();
  const { sendTx } = useTx();

  const [treasury, setTreasury] = React.useState<string>("");
  const [to, setTo] = React.useState<string>("");
  const [amount, setAmount] = React.useState<string>("10");
  const [purpose, setPurpose] = React.useState<string>("0x" + "00".repeat(32));

  const [epoch, setEpoch] = React.useState<string>("1");
  const [inflowAmount, setInflowAmount] = React.useState<string>("100");
  const [reportHash, setReportHash] = React.useState<string>("0x" + "00".repeat(32));

  const canAddr = (s: string) => s.startsWith("0x") && s.length === 42;

  React.useEffect(() => {
    if (typeof window === "undefined") return;
    const a = new URLSearchParams(window.location.search).get("addr");
    if (a && canAddr(a) && !treasury) setTreasury(a);
  }, [treasury]);

  const avail = useQuery({
    queryKey: ["treasuryAvail", treasury],
    enabled: !!client && canAddr(treasury),
    queryFn: async () => {
      if (!client) return 0n;
      const a = (await client.readContract({
        address: treasury as any,
        abi: treasuryAbi,
        functionName: "availableBalance",
        args: []
      })) as bigint;
      return a;
    }
  });

  const pay = async () => {
    const amt = parseUnits(amount || "0", 18);
    await sendTx({
      title: "Treasury pay",
      address: treasury as any,
      abi: treasuryAbi,
      functionName: "pay",
      args: [to as any, amt, purpose as any]
    } as any);
    avail.refetch();
  };

  const noteInflow = async () => {
    const amt = parseUnits(inflowAmount || "0", 18);
    await sendTx({
      title: "Note inflow",
      address: treasury as any,
      abi: treasuryAbi,
      functionName: "noteInflow",
      args: [BigInt(epoch), amt, reportHash as any]
    } as any);
    avail.refetch();
  };

  return (
    <div>
      <PageHeader title="Admin · Treasury" subtitle="Note inflows and pay out with purpose tags." />

      <div className="grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Connect</CardTitle>
            <CardDescription>Set the Treasury module address (per campaign).</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            <Input value={treasury} onChange={(e) => setTreasury(e.target.value)} placeholder="Treasury address (0x...)" />
            <div className="flex items-center justify-between text-sm">
              <span className="text-text2">Available balance</span>
              <span className="font-mono">{avail.isLoading ? "…" : avail.data?.toString() ?? "0"}</span>
            </div>
          </CardContent>
        </Card>

        <div className="grid gap-4 md:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>Pay</CardTitle>
              <CardDescription>Transfers settlement asset from treasury to a recipient.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <Input value={to} onChange={(e) => setTo(e.target.value)} placeholder="Recipient 0x..." />
              <Input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="Amount (18 decimals skeleton)" />
              <Input value={purpose} onChange={(e) => setPurpose(e.target.value)} placeholder="Purpose bytes32" />
              <div className="flex items-center gap-2">
                <Button onClick={pay} disabled={!isConnected || !canAddr(treasury) || !canAddr(to)}>
                  Pay
                </Button>
                {!isConnected ? <Badge tone="warn">Connect wallet</Badge> : null}
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Note inflow</CardTitle>
              <CardDescription>Records off-chain settlement reports (epoch + reportHash).</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <Input value={epoch} onChange={(e) => setEpoch(e.target.value)} placeholder="Epoch" />
              <Input value={inflowAmount} onChange={(e) => setInflowAmount(e.target.value)} placeholder="Amount (18 decimals skeleton)" />
              <Input value={reportHash} onChange={(e) => setReportHash(e.target.value)} placeholder="Report hash bytes32" />
              <div className="flex items-center gap-2">
                <Button onClick={noteInflow} disabled={!isConnected || !canAddr(treasury)}>
                  Note
                </Button>
              </div>
            </CardContent>
          </Card>
        </div>

        <div className="text-xs text-text2 rounded-xl border border-border bg-muted p-3">
          Amount parsing uses 18 decimals as a UI skeleton. In production, read the settlement asset’s decimals via ERC20 and parse accordingly.
        </div>
      </div>
    </div>
  );
}
