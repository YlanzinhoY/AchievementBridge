import { Router, Route } from '@solidjs/router'
import type { ParentProps } from 'solid-js'

import { BridgeCards } from '@/components/cards'
import Navbar from '@/components/layout/Navbar'
import TechStack from '@/components/tech-stack'
import JogosCompativeis from '@/pages/Jogos-Compativeis'
import Logs from '@/pages/Logs';

function Home() {
  return (
    <>
      <BridgeCards />
      <TechStack />
    </>
  )
}

function Layout(props: ParentProps) {
  return (
    <div class="min-h-svh bg-background text-foreground">
      <Navbar />

      <main class="min-h-[calc(100svh-80px)] w-full bg-background">
        {props.children}
      </main>
    </div>
  )
}

function App() {
  return (
    <Router root={Layout}>
      <Route path="/" component={Home} />
      <Route
        path="/jogos-compativeis"
        component={JogosCompativeis}
      />
      <Route
        path="/bridge-logs"
        component={Logs}
        />
    </Router>
  )
}

export default App
