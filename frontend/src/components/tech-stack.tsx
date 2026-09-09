import { For, type JSXElement } from "solid-js"

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "./ui/card"

type TechStackArea = "Core" | "UI"

type TechStackType = {
  Id: number
  Name: string
  Description: string
  Area: TechStackArea
  IconTag: JSXElement
}

const stacks: TechStackType[] = [
  {
    Id: 1,
    Name: "Zig",
    Description:
      "Responsável pela integração com a Steam e pelo monitoramento das conquistas em tempo real.",
    Area: "Core",
    IconTag: <i class="devicon-zig-original colored text-3xl" aria-hidden="true" />,
  },
  {
    Id: 2,
    Name: "Go",
    Description:
      "Expõe a API local e coordena a comunicação entre a interface e o núcleo escrito em Zig.",
    Area: "Core",
    IconTag: <i class="devicon-go-original-wordmark colored text-4xl" aria-hidden="true" />,
  },
  {
    Id: 3,
    Name: "TypeScript",
    Description:
      "Adiciona tipagem estática e mais segurança ao desenvolvimento da interface.",
    Area: "UI",
    IconTag: <i class="devicon-typescript-plain colored text-3xl" aria-hidden="true" />,
  },
  {
    Id: 4,
    Name: "SolidJS",
    Description:
      "Constrói a interface reativa e os componentes exibidos no aplicativo.",
    Area: "UI",
    IconTag: <i class="devicon-solidjs-plain colored text-3xl" aria-hidden="true" />,
  },
  {
    Id: 5,
    Name: "Python",
    Description:
      "Implementa a CLI com Typer e dá suporte às rotinas auxiliares do projeto.",
    Area: "UI",
    IconTag: <i class="devicon-python-plain colored text-3xl" aria-hidden="true" />,
  },
]

const areas: Array<{
  Name: TechStackArea
  Description: string
  GridClass: string
}> = [
  {
    Name: "Core",
    Description: "Tecnologias responsáveis pela integração e pelas regras centrais do bridge.",
    GridClass: "sm:grid-cols-2",
  },
  {
    Name: "UI",
    Description: "Tecnologias usadas na interface e nas ferramentas de apoio do projeto.",
    GridClass: "sm:grid-cols-2 lg:grid-cols-3",
  },
]

export default function TechStack() {
  return (
    <section
      id="tech-stack"
      aria-labelledby="tech-stack-title"
      class="mx-auto w-full max-w-7xl px-4 py-10 sm:px-6 lg:px-8"
    >
      <div class="mb-6 max-w-2xl">
        <p class="text-sm font-semibold uppercase tracking-wider text-muted-foreground">
          Tecnologias
        </p>
        <h2 id="tech-stack-title" class="mt-1 text-2xl font-bold tracking-tight sm:text-3xl">
          Stack do Achievement Bridge
        </h2>
        <p class="mt-2 text-sm leading-relaxed text-muted-foreground sm:text-base">
          As ferramentas que conectam o núcleo do bridge à interface usada no dia a dia.
        </p>
      </div>

      <div class="grid gap-4">
        <For each={areas}>
          {(area) => (
            <Card class="min-w-0 overflow-hidden">
              <CardHeader class="border-b bg-muted/30">
                <CardTitle>{area.Name}</CardTitle>
                <CardDescription>{area.Description}</CardDescription>
              </CardHeader>
              <CardContent class="pt-6">
                <div class={`grid gap-3 ${area.GridClass}`}>
                  <For each={stacks.filter((stack) => stack.Area === area.Name)}>
                    {(stack) => (
                      <article
                        id={`tech-${stack.Id}`}
                        class="flex min-w-0 items-start gap-4 rounded-lg border bg-background p-4 shadow-sm"
                      >
                        <div class="grid size-12 shrink-0 place-items-center rounded-lg border bg-muted/50 shadow-sm [&>i]:leading-none">
                          {stack.IconTag}
                        </div>
                        <div class="min-w-0">
                          <h3 class="font-semibold leading-none">{stack.Name}</h3>
                          <p class="mt-2 text-sm leading-relaxed text-muted-foreground">
                            {stack.Description}
                          </p>
                        </div>
                      </article>
                    )}
                  </For>
                </div>
              </CardContent>
            </Card>
          )}
        </For>
      </div>
    </section>
  )
}
