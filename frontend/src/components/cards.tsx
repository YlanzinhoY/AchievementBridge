import {
  Card,
  CardHeader,
} from "./ui/card"

export function BridgeCards() {
  return (
    <div class="mx-auto grid w-full max-w-7xl grid-cols-[repeat(auto-fit,minmax(min(100%,18rem),1fr))] gap-3 px-4 sm:px-6 lg:px-8">
      <Card class="min-w-0">
        <CardHeader>
          Ver jogos compativeis
        </CardHeader>
      </Card>
      <Card class="min-w-0">
        <CardHeader>
          Ver conquistas disponiveis
        </CardHeader>
      </Card>
      <Card class="min-w-0">
        <CardHeader>
          Desativar o bridge
        </CardHeader>
      </Card>
      <Card class="min-w-0">
        <CardHeader>
          Status
        </CardHeader>
      </Card>
    </div>
  )
}
