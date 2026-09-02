# iperf3 (Fase 2 do DICON) — licenças de terceiros

Binários do `iperf3` para Windows 64-bit (build `iperf3.21_64`, ar51an/iperf3-win-builds),
distribuídos junto com o DICON. Todos os componentes abaixo permitem redistribuição.

| Arquivo             | Componente            | Licença                       |
|---------------------|-----------------------|-------------------------------|
| `iperf3.exe`        | iperf3 3.21 (ESnet)   | BSD-3-Clause                  |
| `cygwin1.dll`       | Cygwin runtime        | LGPL v3                       |
| `cygcrypto-3.dll`   | OpenSSL 3.x           | Apache License 2.0           |
| `cygz.dll`          | zlib                  | zlib License                  |

## iperf3 — BSD-3-Clause

> Copyright (c) 2014-2024, The Regents of the University of California,
> through Lawrence Berkeley National Laboratory (subject to receipt of any
> required approvals from the U.S. Dept. of Energy). All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are met:
> (1) redistributions of source code retain the copyright notice, this list of
> conditions and the following disclaimer; (2) redistributions in binary form
> reproduce the copyright notice, this list of conditions and the disclaimer in
> the documentation and/or other materials provided with the distribution;
> (3) neither the name of the University nor the names of its contributors may
> be used to endorse or promote products derived from this software without
> specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
> AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED. Texto completo:
> https://github.com/esnet/iperf/blob/master/LICENSE

## cygwin1.dll — LGPL v3

O runtime do Cygwin (`cygwin1.dll`) é distribuído sob a GNU Lesser General
Public License, versão 3. O DICON usa a DLL sem modificação, apenas como
dependência do `iperf3.exe`. Texto da licença: https://www.gnu.org/licenses/lgpl-3.0.html
Código-fonte do Cygwin: https://www.cygwin.com/ (git://sourceware.org/git/newlib-cygwin.git)

## cygcrypto-3.dll — Apache License 2.0 (OpenSSL 3)

https://www.openssl.org/source/apache-license-2.0.txt

## cygz.dll — zlib License

https://zlib.net/zlib_license.html

---

Origem dos binários: https://github.com/ar51an/iperf3-win-builds
(`iperf3.21_64.zip`). Substituir os 4 arquivos por uma versão mais nova é só
recolocar aqui e commitar — o setup do DICON leva `bin/iperf3/` como está.
