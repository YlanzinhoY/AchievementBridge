# Achievement Bridge

> ⚠️ **Beta em desenvolvimento.** O Achievement Bridge está sendo construído ativamente e pode mudar, ter limitações ou apresentar falhas entre versões.

O Achievement Bridge conecta conquistas locais à Steam no Windows. O foco é ampliar a compatibilidade entre jogos para que a experiência de desbloquear e acompanhar conquistas seja melhor e mais consistente.

Alguns jogos já integram conquistas à Steam naturalmente; outros usam provedores, launchers ou estados locais diferentes. A ideia do Bridge é unificar esses caminhos para oferecer uma experiência fidedigna.

O projeto reúne uma aplicação em Go, um núcleo nativo pequeno em Zig e interfaces em Python e SolidJS. A partir da versão 0.3, o Go monitora somente o jogo que estiver aberto; o Zig fica concentrado na ABI da Steam, cache e integrações nativas.

## Estado do projeto

Ainda estamos em beta. A compatibilidade varia por jogo e provedor; novas integrações e melhorias estão em andamento.

Já foi testado com **Onimusha: Way of the Sword**, **Assassin's Creed Black Flag Resynced**, **GTA V Enhanced** e **Metal Gear Solid V**.

Encontrou algum erro ou quer pedir compatibilidade para um jogo? Fale comigo no [Discord do Bummy](https://discord.com/invite/JJMEKgmF3a).

## Licença

Distribuído sob a [MIT License](LICENSE).
