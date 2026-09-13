# ACK BYOCNI 本地化运维迁移记录

本文记录 Alibaba Cloud ACK Cilium/Tetragon Demo 从 Cloud Shell/手工混合运维迁移到本地 Mac 全生命周期自动化的实施与验证。权威任务书为 `.agent-context/ack-byocni-local-migration-taskbook.md`。

## Before

- Terraform 预期在 Cloud Shell 执行，本地 Mac 只运行部分 kubectl/Helm 步骤。
- kubeconfig 需要人工复制或依赖全局 current-context，容易与 AWS EKS context 混淆。
- `kup` 只有 Cilium 与应用安装片段，使用硬编码绝对路径，无 preflight、Terraform、私有 kubeconfig 或幂等 namespace 处理。
- Tetragon 由独立 `tup` 安装，生命周期入口分散。
- Cilium values 开启 chart 内置 Integrated Timescape，并带有 Integrated-only `ingester.k8sImporter` 配置。
- 销毁入口尚不存在；旧命名与工作方式以 `killall`/独立步骤为背景。

## After

- 正常 lifecycle 完全在本地 Mac 执行，唯一入口为 `./kup` 和 `./kiall`。
- Terraform 管理 ACK Pro、VPC、vSwitch、NAT/public API 配置与固定 3-Worker Node Pool。
- `kup.conf` 统一私有配置；公开 example 对 ACK 与 Galileo 的所有敏感值只提供 `ReplaceMe`，Enterprise repository 变量名和值都不进入 example。
- ACK kubeconfig 固定为项目内 `./kubeconfig`，context 归一化为 `ack-byocni-demo`。所有 kubectl/Helm 命令显式指定 kubeconfig/context，不 merge 或修改 `~/.kube/config`。
- 保留 ACK BYOCNI、Kubernetes IPAM、VPC Route/Native Routing、KPR、Hubble Relay 与 AliyunLinux3 BPF LSM bootstrap。
- Integrated Timescape 完全移除，替换为 AWS 本地参考已验证的 Hubble UI Enterprise + Standalone Timescape Lite + Hubble Enterprise fluentd HTTP push pipeline。
- Tetragon Enterprise 与 Tetragon Policy Ruleset 合并进 `kup`。
- 保留 Alibaba Registry mini-boutique、testcurl 与非阻断 L7 visibility CNP。
- `kiall` 仅执行 Terraform state 边界内的 `terraform destroy -auto-approve`，不进行 Kubernetes 优雅卸载或账号/区域/VPC 扫描清理。

## Inventory and disposition

迁移开始时检查的当前文件：

- `kup`、`kup.conf`、`cilium-enterprise-values.yaml`
- `tup`、`tetragon-tpr.yaml`、`tpr-values-ack-1.18.yaml`
- `getk8sinfo.sh`、`temp.json`
- `ns_test/testcurl.yaml`
- `ns_demo/mini-boutique-lite.yaml`、`ns_demo/cnp-l7-visibility.yaml`、`ns_demo/boutique.yaml`
- `.gitignore` 与权威 taskbook

保留并工程化：

- `ns_test/testcurl.yaml`
- `ns_demo/mini-boutique-lite.yaml`
- `ns_demo/cnp-l7-visibility.yaml`
- 私有 `kup.conf`（继续 ignore）

新增或重写：

- `main.tf`、`.terraform.lock.hcl`
- `kup`、`kiall`、`kup.conf.example`
- `cilium-enterprise-values.yaml`
- `hubble-enterprise-values.yaml`、`hubble-timescape-values.yaml`、`hubble-ui-values.yaml`
- `tetragon.yaml`、`tpr-values.yaml`
- `README.md`、`docs/MIGRATION.md`

确认不再需要并迁入 `.bak/<migration timestamp>/` 后从工作树原位置移除：

- `tup`：Tetragon 已合并到 `kup`。
- `tetragon-tpr.yaml`、`tpr-values-ack-1.18.yaml`：由规范命名且可渲染的新 values 替代。
- `getk8sinfo.sh`：依赖全局 context，检查能力已进入 `kup` 与 README 的显式 kubeconfig 命令。
- `temp.json`：旧的运行期采样数据。
- `ns_demo/boutique.yaml`：会创建公网 LoadBalancer 的完整版本；baseline 保留轻量且 Alibaba-friendly 的 `mini-boutique-lite.yaml`。
- `.DS_Store`：本地 Finder 元数据。

上述旧文件保存在 `.bak/20260912-local-migration/`；`.bak/` 本身被 Git ignore。原 `kup` 与 Cilium values 是同路径增量重写，而不是删除项。

`killall` 名称废弃，因为新入口 `kiall` 清楚对应任务书约定，且其语义严格限定为 Terraform state-owned destroy，不复制 AWS 的 aggressive nuke 行为。

## Terraform design

- Terraform CLI：1.x（实施验证机安装 1.16.1）。
- Provider：`aliyun/alicloud` 固定 `1.279.0`，不使用浮动下限；`.terraform.lock.hcl` 提交。
- Credentials：仅由 `kup.conf` source 后通过环境变量传给 Provider，不写入 HCL 或 tracked tfvars。
- Networking：Terraform 创建 `10.10.0.0/16` VPC 与 `10.10.1.0/24` worker vSwitch；Pod `172.20.0.0/16`、Service `172.21.0.0/20`，脚本 preflight 验证 CIDR 不重叠。
- BYOCNI：创建 ACK Managed Pro 时禁用 `kube-flannel-ds`；`cloud-controller-manager` 使用 `EnableCloudRoutes=true` 与 `BackendType=NodePort`；设置 `pod_cidr` 与 `/24` `node_cidr_mask`。
- Node Pool：3 个按量付费 `ecs.e-c1m2.xlarge`、AliyunLinux3 Container Optimized、containerd、40 GiB `cloud_essd_entry`，以满足 ACK 当前 cgroup v2 要求、standalone ClickHouse 4 GiB request 与每节点 Tetragon request。
- BPF LSM：base64 `user_data` 检查 `/sys/kernel/security/lsm`；已含 `bpf` 则退出，否则用 `grubby` 写入 `lsm=<existing>,bpf`，写 marker 并安排一次重启。marker 阻止反复修改或 reboot loop。
- kubeconfig：`alicloud_cs_cluster_credential` 直接写项目 `kubeconfig`，随后 `kup` chmod 600 并 rename 为稳定 alias。
- Ownership：不创建 UI LoadBalancer、Timescape PVC、额外 ECS/EIP/SLB。ACK 需要的 NAT/public API 资源由 cluster resource 生命周期管理。

## Helm architecture and pinned versions

| Component | Chart | Version | Source/adaptation |
|---|---|---:|---|
| Cilium Enterprise | `isovalent/cilium` | 1.18.11 | Alibaba working values：Kubernetes IPAM、native routing、KPR、Hubble Relay；移除 Integrated Timescape/ServiceMonitor |
| Hubble UI Enterprise | `isovalent/hubble-ui` | 1.3.12 | 按本地 AWS values 与安装顺序复制 |
| Hubble Timescape | `isovalent/hubble-timescape` | 1.8.4 | 按本地 AWS standalone Lite values 复制，无 `k8sImporter` |
| Hubble Enterprise | `isovalent/hubble-enterprise` | 1.13.4 | 按本地 AWS fluentd HTTP push pipeline 复制 |
| Tetragon Enterprise | `isovalent/tetragon` | 1.18.5 | AWS network export/field/noise 策略，适配 AliyunLinux3/containerd；内存 request 按实测从 1 GiB 最小调整为 512 MiB；移除 ServiceMonitor/dashboard/Application Model/filesystem SCA baseline |
| Tetragon Policies | `isovalent/tetragon-policies` | 1.18.2 | AWS ruleset 结构，profile 从 `aws-eks` 改为 `generic-linux` + `containerd`，删除 AWS SSM/应用专用 trusted paths，加入 ACK 常见路径/labels |

Hubble Enterprise 内部目标保持：

```text
http://hubble-timescape-ingester.kube-system.svc.cluster.local:4260/push
```

安装顺序保持本地 AWS working implementation：Hubble UI -> standalone Timescape -> Hubble Enterprise。与 AWS 脚本不同，ACK 版本不会吞掉 Helm 错误，所有命令显式使用项目 kubeconfig/context，并等待 release 健康。

## Alibaba-specific adaptations

- EKS/ENI IPAM 替换为 ACK Pro BYOCNI + Kubernetes IPAM。
- AWS VPC/CloudFormation/eksctl/SSM/EC2 SG 全部替换为 `aliyun/alicloud` Terraform resource。
- 节点 BPF LSM bootstrap 使用 ACK Node Pool `user_data`，不使用 SSM。
- 使用 ACK `cloud-controller-manager` 自动维护每节点 PodCIDR VPC route。
- Worker 为 AliyunLinux3/containerd，应用镜像保持 Alibaba Registry 版本。
- kubeconfig 不进入全局文件，避免和 AWS EKS context 互相影响。

## AWS logic intentionally not migrated

- EKS、AWS ENI IPAM、eksctl、CloudFormation、AWS CLI、SSM、EC2 Security Group 与 remote-outpost。
- kube-prometheus-stack、Grafana、dashboards、OpenTelemetry Demo。
- Egress Gateway/HA/failover、Splunk Universal Forwarder。
- Vulhub/Shiro/reverse-shell/brute-force victim workloads。
- Advanced Tetragon policies、Application Model、filesystem SCA。

这些功能属于 README Roadmap，不进入 baseline。

## Validation log

状态会按实际执行结果持续更新；不把尚未运行的步骤写成通过。

| Test | Status | Evidence / result |
|---|---|---|
| A Static: Bash syntax | passed | 多次运行 `bash -n kup kiall`，最终版本返回 0 |
| A Static: Terraform | passed | `terraform fmt -check -recursive` 与 `terraform validate` 返回 0；Provider lock 生效 |
| A Static: Helm | passed | 每次 `kup` 都对六个 pinned chart 执行 `helm show chart/values` 与 `helm template`；最终每个 release 另经 `deployed` 状态门禁 |
| B From zero | passed | 空 state 的 `./kup` 创建 4 个 Terraform resource、ACK Pro 与 3 个 Worker；最终 baseline 全部收敛 |
| C Cilium datapath | passed | 3/3 Node Ready 且分配 `/24` PodCIDR；`cilium-dbg status`：Kubernetes Ok、KPR True、Native/BPF routing、Kubernetes IPAM、Hubble Ok |
| D Application networking | passed | `kup` 硬检查 DNS、跨节点 pod-to-pod ping、frontend Service、三个节点到 frontend、`https://www.cisco.com/` 均通过 |
| E Hubble UI | passed | 实际 port-forward 打开 UI；Overview/Live 为 3/3 nodes 且约 140 flows/s，Historical 5-minute 显示 testcurl -> frontend 与下游 HTTP/gRPC flow |
| F Timescape | passed | Timescape/ClickHouse 2/2 Ready；3 个 Fluentd tail `hubble.log`，Timescape 持续 flush 非零 flows/s，UI historical 查询有数据 |
| G Tetragon | passed | 3/3 Agent Ready；每节点 probe 含 `HaveProgramType(ebpf.LSM) = true`，network/alert 文件非空；8 TracingPolicy、24 AlertRule |
| H Repeat kup | passed | 多次 `./kup` 成功；Terraform 报 `0 added, 0 changed, 0 destroyed`，没有第二套 ACK/VPC，所有硬检查重复通过 |
| I Destroy | passed | `./kiall` 实际删除 4 个 Terraform resource，state 为空且 kubeconfig 仅在成功后删除；global context 前后均为 `k8s-demo-0-0` |
| J Repeat destroy | passed | empty state 上再次 `./kiall`：`0 destroyed`、exit 0；一次 UI 误中断后的 partial destroy 也由同一 state 安全续完 |
| K Rebuild | passed | destroy 后从空 state 创建新 VPC/ACK/3 Worker，并完成全套运行期验证；随后修复受 API 断线影响的 pending Helm metadata，最终六个核心 release 全为 `deployed` |

## Tested lifecycle

2026-09-12 在真实 Alibaba Cloud 账号与 `cn-wulanchabu` region 实际执行：

```text
terraform validate
six pinned helm template validations
kup from zero
re-run kup (Terraform zero diff)
kiall (four resources destroyed)
re-run kiall (zero resources)
rebuild from empty state
re-run kup after transient/interrupted Helm metadata recovery
```

最终集群保留运行；项目私有 context 为 `ack-byocni-demo`，`kup.conf` 与 kubeconfig mode 均为 0600。Terraform 当前 state 含 4 个 resource 与 2 个 data object；全局 current-context 始终保持 `k8s-demo-0-0`。

## Validated versions

| Component | Validated version |
|---|---:|
| Terraform | 1.16.1 |
| Alibaba Provider | 1.279.0 |
| ACK Kubernetes | 1.36.2-aliyun.1 |
| Cilium Enterprise | 1.18.11 |
| Tetragon Enterprise | 1.18.5 |
| Tetragon Policies | 1.18.2 |
| Hubble Enterprise | 1.13.4 |
| Hubble Timescape | 1.8.4 |
| Hubble UI | 1.3.12 |

## Errors and resolutions

- 初始环境缺少 Terraform。Homebrew core 已不再提供该 formula；添加 HashiCorp 官方 tap 后安装 Terraform 1.16.1。
- 初始 Worker 规格 `ecs.e-c1m2.large` 只有 4 GiB 级别内存，无法容纳 AWS reference 中 ClickHouse 的 4 GiB request 及节点系统/Tetragon 开销。默认提升到同系列 `ecs.e-c1m2.xlarge`（4 vCPU/8 GiB），待真实 ACK 调度验证。
- 第一次 `kup` 的 Terraform plan 在创建任何资源前拒绝 `alicloud_zones.available_disk_category = cloud_essd_entry`，因为 data source 过滤器枚举不包含该新磁盘类别。移除可用区查询中的磁盘过滤、保留实例规格过滤；Node Pool 的实际 `system_disk_category` 不变。
- 第二次 `kup` 成功创建 VPC、vSwitch 与 ACK 控制面，但 ACK API 拒绝普通 `AliyunLinux3` Node Pool：当前默认 Kubernetes 要求 cgroup v2，而选中的普通镜像不支持。改为官方 `AliyunLinux3ContainerOptimized` image type；控制面/state 保留并由下一次 `kup` 继续收敛。
- 第三次 `kup` 创建 3 个 Worker，Cilium、Hubble UI、Standalone Timescape/ClickHouse 与 Hubble Enterprise 均成功；Tetragon 有 2/3 Agent Ready，固定到 Timescape 节点的第三个 Agent 因内存 request 不足 Pending（该节点已请求 4638 MiB/约 5.2 GiB allocatable）。按任务书要求先实测再做最小调整，将 Tetragon memory request 从 AWS 的 1 GiB 降到 512 MiB，保留 2 GiB limit。
- 中断恢复时一次 ACK/VPC refresh 遭遇 TLS connection reset；state 与现有资源未改变。Provider 原始错误 URL 会带签名查询参数，因此为 `kup` 与 `kiall` 的 Terraform 输出统一增加基于环境变量字面值替换的脱敏过滤，同时保留 `pipefail` 传播真实退出码。
- 应用首次网络检查发现 `testcurl` 的旧 shell 命令中 `&` 会把 `sed && apk add && telnetd` 整条链放到后台，导致 Pod Ready 时 `curl` 仍不存在。改为前台安装 `curl/busybox-extras`、启动 telnetd 后 exec sleep，并增加检查 `curl/nslookup` 的 readinessProbe；同时把镜像内已有的 USTC 或其他 Alpine 源统一改写为阿里云镜像源，避免只替换默认域名却未命中。
- Alibaba Registry 的 `currencyservice` 与 `paymentservice` 镜像会默认启动 Google Cloud Profiler，在 ACK 上因缺少 Google Project ID 周期性退出，继而令 frontend 返回 HTTP 500。为这两个现有 Alibaba 镜像设置官方 `DISABLE_PROFILER=1`，并在 Deployment Available 之外增加所有现存 Demo Pod Ready 的硬等待，避免接受短暂保留的 stale Available condition。
- 后续收敛时 ACK 公网 API 的 HTTP/2 连接在 Helm 写 Cilium release secret 时丢失。资源仍健康；给六个核心 `helm upgrade --install` 增加最多 3 次、间隔 15 秒的有限重试，超过次数仍硬失败，避免 silent ignore。
- 同一次连接中断留下 Cilium 最新 revision 为 `pending-upgrade`。`kup` 会识别并只删除最新 `pending-*` revision 的 Helm Secret，再继续同名 release 的幂等收敛；不会删除 deployed revision 或任意 Kubernetes workload。后续 fresh install 也实测覆盖了没有稳定前序 revision 的 `pending-install` 恢复。
- 首次 Tetragon runtime 检查尝试直接读取容器内 `/sys/kernel/security/lsm`，但当前 chart 不挂载 securityfs，路径不可见并不等于 Host 未启用 BPF LSM。验证改为要求每个 Agent 的 Tetragon 探测日志包含 `HaveProgramType(ebpf.LSM) = true`，同时要求每个节点的 network event 文件与至少一个 AlertRule 文件非空；实测 3 个 Agent 均有 MiB 级事件/告警输出。
- Hubble UI 实际打开后，Overview 显示 Timescape ready、3/3 Relay nodes connected 且有实时 flows/s，但 historical 查询无数据。对照 AWS working Cilium values 后确认精简时遗漏了 `/var/run/cilium/hubble/hubble.log` flow export；Hubble Enterprise Fluentd 因此只有 Tetragon/status 输入、没有 flow 文件可推送。ACK 版本使用当前 chart 的正式 `hubble.export.static` 键恢复相同文件路径（避免 AWS `extraConfig.export-file-path` 在 Cilium 1.19 的弃用提示），并仅在 export 文件尚不存在时执行一次 Cilium DaemonSet rollout；稳定重跑不会无条件重启 datapath。
- 恢复 export 后，3 个节点的 `hubble.log` 均非空（约 42–64 MiB），3 个 Fluentd 实例都开始 tail，Timescape 日志持续报告约 100–300 flows/s flushed。Hubble UI historical 5-minute view 实际显示 testcurl -> frontend 与 frontend -> currency/cart/product/ad 等 HTTP/gRPC L7 记录；Live View 同时显示 3/3 nodes 与约 140 flows/s。`kup` 增加对应硬检查：所有 Fluentd 节点必须 tail `hubble.log`，且 Timescape 必须出现非零 flow flush。
- Pipeline 检查最初用 `--since=10m` 查找 Fluentd 的一次性 “following tail” 日志，稳定环境运行超过 10 分钟后会误判；改为检查容器当前保留日志的最近 2000 行。Timescape 的持续 flush 仍限定在最近 10 分钟，既支持幂等重跑也能证明当前 ingestion 活跃。
- Destroy 后 rebuild 的 fresh Cilium install 暴露两个收敛竞态：exporter 文件检查早于 Cilium 首次 Ready，造成一次无害但不必要的 rollout；BPF LSM 的计划重启期间 Hubble Relay 的 Service endpoint 会短暂为空。export 检查现移至第一次 Cilium/Node 健康等待之后（仅旧进程缺配置才滚动），Service endpoint 检查改为最多 5 分钟的有界等待，仍在超时后硬失败并输出 Service 诊断。
- Rebuild 后的幂等重跑再次在 ACK refresh 的 `DescribeNatGateways` 遇到 VPC API connection reset，资源未改变且凭据脱敏生效。`terraform apply` 与 `terraform destroy` 现增加最多 3 次、间隔 15 秒的有限重试；非瞬时错误在第三次后仍返回非零状态，destroy 未成功时仍保留 state 与 kubeconfig。
- 最终 lifecycle 的一次人为中断发生在 destroy 已移除部分 state 后；按设计 state 与 kubeconfig 均保留并可续跑。该中断同时发现 Provider refresh 会重新生成 0644 kubeconfig，`kiall` 现增加 EXIT trap：只要文件仍存在，无论成功、失败、Ctrl-C 都恢复 0600；完整 destroy 成功后仍删除该文件。
- 一次完整 fresh `kup` 的运行期检查全部通过且命令返回 0，但 Helm 最终清单显示 Cilium 与 Timescape 因 ACK API 在写最终 release Secret 时断线而停在 `pending-install`。`helm upgrade` 在该场景仍返回 0，单靠进程退出码不足。`kup` 现对每次 Helm 操作额外读取 release status 并强制要求 `deployed`；重试前仅删除最新的 `pending-*` revision Secret（包括没有稳定前序 revision 的 interrupted install），不删除 workload 或任何 deployed revision。

## Galileo application extension — 2026-09-13

- 上游来源固定为 `https://github.com/highopes/galileo-demo` commit `bb87e2ceec3e75cf875417984be3de3131e34ea0`。`kup` 不在 lifecycle 中临时 clone 或 build；部署该提交已完成 smoke/push 的 `linux/amd64` ACR immutable digest，避免 Docker/Colima 与 mutable tag 依赖。
- 新增 `ns_galileo/multi-agent-banking.yaml`：`galileo-demo` Namespace、非 Secret ConfigMap、单副本 non-root Deployment 与 ClusterIP Service。禁用 ServiceAccount token、drop all capabilities，不创建 LoadBalancer、Ingress、PVC 或新的 ACR/Pinecone/Splunk AO 控制面资源。
- `kup.conf.example` 增加完整 `GALILEO_*` 接口，敏感字段只有 `ReplaceMe`；真实 ACR、Splunk AO、百炼、Pinecone 值已从获授权的本地 Galileo `.secrets`/resolved runtime 写入 ignored、0600 的 `kup.conf`。VLLM Judge key、Docker Hub PAT 与 Alibaba RAM credential 不注入应用 Pod。
- `kup` 使用临时 0600 文件生成 runtime Secret 与 Docker config Secret，apply 后通过 trap 立即清理；Terraform/命令输出脱敏器也覆盖新增凭据。
- 新增硬检查：Deployment 必须使用配置的 `@sha256` digest，Service 必须有 endpoint，testcurl 必须能访问 Chainlit HTTP；Pod 内上游 `pod_network_smoke.py` 必须验证应用模型 DNS/TLS/认证与精确 model ID、Pinecone integrated text search 和 Splunk AO HTTPS。
- 第一次纳入 `kup` 时 Deployment 已完成滚动且新 Pod Ready，但紧随其后的 `kubectl exec deployment/...` 仍选中正在删除的旧 Replica，返回 Pod NotFound。验证现显式选择没有 deletion timestamp 且 Ready 的当前 Pod，并进行最多三次、间隔 5 秒的有界 exec；最终失败仍是硬错误。
- 状态：passed。修复上述 Replica 竞态后，定向检查确认镜像 digest、ClusterIP HTTP、应用模型、Pinecone 与 Splunk AO 全部通过；随后完整重复执行 `./kup` 返回 0，Terraform 为 `0 added, 0 changed, 0 destroyed`，Galileo Secret/Service 幂等保持、Deployment 为 1/1 Ready，全部原有 ACK/Cilium/Hubble/Tetragon/mini-boutique 检查也再次通过。期间 ACK API 的一次短暂连接超时及一个 Timescape pending revision 均由既有限重试/精确恢复逻辑收敛。

## Acceptance result and remaining issues

Migration completed。正常路径已是 Mac-only `kup`/`kiall`，Cloud Shell、Integrated Timescape、独立 `tup`、全局 kube context 与 state 外 aggressive cleanup 都不在 baseline。`kup -> kup -> kiall -> kiall -> kup` 的真实基础设施生命周期已覆盖；Galileo 扩展也已完成真实部署、定向检查和完整 zero-diff `kup` 重跑，并额外验证中断销毁恢复、pending Helm revision 恢复。Roadmap 项未进入 baseline。

没有已知的 migration 功能阻塞。Alibaba VPC/ACK API 在验证期间出现过短暂 connection reset/HTTP2 loss；有限重试、Helm `deployed` 门禁和幂等重跑已实测恢复，最终不再有 pending release。

安全后续：在输出脱敏加入之前，Provider 的一次失败 URL 曾把本次验证所用 RAM AccessKey ID（没有 Secret/password）写入本地任务 transcript。虽然签名参数已过期，仍建议验证后轮换该 RAM AccessKey pair；文档和 tracked 文件中没有写入该值。
