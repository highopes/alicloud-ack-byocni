# ACK BYOCNI Cilium/Tetragon Demo

本仓库从本地 MacBook 一键创建和销毁 Alibaba Cloud ACK Managed Kubernetes Pro 演示环境。正常生命周期只有两个入口：

```bash
./kup
./kiall
```

`kup` 使用 Terraform 创建 ACK、VPC、vSwitch、NAT 与 3 个 Worker，再通过项目私有 kubeconfig 安装 Cilium Enterprise、Hubble Enterprise、Standalone Timescape Lite、Hubble UI Enterprise、Tetragon Enterprise、Tetragon Policies、Alibaba Registry 版本的 mini-boutique、非阻断式 L7 visibility policy，以及 [Galileo Multi-agent banking chatbot](https://github.com/highopes/galileo-demo)。`kiall` 只销毁当前 Terraform state 拥有的资源。

## Architecture

```text
MacBook
  |-- Terraform --------------------------> ACK Pro / VPC / workers
  |-- kubectl + Helm (private kubeconfig)     |
                                               +-- Cilium Enterprise
                                               |     +-- Native Routing
                                               |     +-- Kubernetes IPAM
                                               |     +-- Kube Proxy Replacement
                                               |     +-- Hubble Relay
                                               |
                                               +-- Hubble UI Enterprise
                                               |     +-- live: Hubble Relay
                                               |     +-- history: Timescape
                                               |
                                               +-- Hubble Enterprise --push--+
                                               |                           |
                                               +-- Standalone Timescape <--+
                                               |     +-- ephemeral ClickHouse
                                               |
                                               +-- Tetragon Enterprise
                                               |     +-- Tetragon Policies
                                               |     +-- network/alert logs
                                               |
                                               +-- demo: mini-boutique + L7 CNP
                                               +-- test: testcurl DaemonSet
                                               +-- galileo-demo
                                                     +-- Chainlit / LangGraph
                                                     +-- Bailian Qwen application model
                                                     +-- Pinecone integrated search
                                                     +-- Splunk Agent Observability
```

这是 ACK BYOCNI + VPC Route/Native Routing 方案，不是 Terway chaining。Cilium chart 内置的 Integrated Timescape 已禁用；历史流量使用独立的 Timescape Lite，Hubble Enterprise 按 AWS 已验证方案把 flow 推送到其 ingestion endpoint。UI 使用 ClusterIP 与本地 port-forward，不创建公网 LoadBalancer。

## One-time Alibaba prerequisites

使用 Alibaba Cloud 中国站账号，并确认后付费账户可用且余额足以创建 ACK Pro、3 台按量付费 ECS Worker、NAT Gateway 与公网 API Server SLB。正常流程不使用 Cloud Shell。

1. 首次进入 ACK 控制台时激活 ACK 服务，并接受 ACK 所需的 Service Role / Quick Authorization。
2. 如果 `AliyunOOSLifecycleHook4CSRole` 等服务角色需要短信、人脸或其他人工安全验证，在控制台完成一次性授权。
3. 创建专用 RAM User。它需要管理本 Demo 涉及的 ACK/CS、ECS、VPC、vSwitch、NAT、EIP/SLB，以及读取可用区和实例规格的权限。可按组织要求授予相应 Alibaba Cloud 系统策略，或使用覆盖这些操作的最小权限自定义策略。不要使用主账号 AccessKey；Cloud Shell 专用权限不再需要。
4. 为 RAM User 创建 AccessKey：
   - 登录 Alibaba Cloud Console。
   - 打开 **Resource Access Management (RAM)**。
   - 进入 **Identities -> Users**。
   - 选择 Demo 自动化使用的 RAM User。
   - 打开 **Credential / Authentication** 页面。
   - 找到 **AccessKey**，点击 **Create AccessKey**。
   - 完成短信、人脸或其他安全验证。
   - 立即保存 AccessKey ID 与 AccessKey Secret。

AccessKey Secret 通常只完整显示一次。如果已经无法取得旧 Secret，请新建一对 AccessKey 并废弃旧 Key，不要尝试恢复。

## Mac prerequisites

本地 Mac 需要：

- Terraform 1.7 或更新的 1.x
- kubectl
- Helm
- Python 3
- curl、awk、sed、base64

Homebrew 示例：

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform kubectl helm python3
```

## Configure

```bash
cp kup.conf.example kup.conf
vim kup.conf
```

先填写 ACK 的三个基础凭据：

```bash
ALICLOUD_ACCESS_KEY="ReplaceMe"
ALICLOUD_SECRET_KEY="ReplaceMe"
ACK_NODE_PASSWORD="ReplaceMe"
```

`ACK_NODE_PASSWORD` 不是从 Alibaba Cloud 查询得到的；它是创建 Worker Node Pool 时由你设置的 ECS 登录密码。为这个 disposable Demo 创建一个满足 Alibaba Cloud 规则的独立强密码。正常演示不依赖 SSH。

Galileo 应用还需要填写以下 `GALILEO_*` 设置；`kup.conf.example` 只提供 `ReplaceMe`，真实值只能留在私有 `kup.conf`：

```text
GALILEO_IMAGE_REF                 ACR 中 linux/amd64 immutable @sha256 digest
GALILEO_REGISTRY_SERVER          ACR registry host
GALILEO_REGISTRY_USERNAME        ACR pull username
GALILEO_REGISTRY_PASSWORD        ACR pull password
GALILEO_SPLUNK_AO_API_KEY        Splunk Agent Observability API key
GALILEO_APP_MODEL_BASE_URL       OpenAI-compatible HTTPS endpoint
GALILEO_APP_MODEL_API_KEY        当前应用模型的 API key
GALILEO_PINECONE_API_KEY         Pinecone API key
```

本次验证的私有 `kup.conf` 已从同级 Galileo working copy 的 `.secrets` 与 `.runtime` resolved files 初始化：应用使用百炼 `qwen3.7-flash`、隔离 Pinecone index `credit-card-information-qwen-demo`，镜像固定为上游 commit `bb87e2ceec3e75cf875417984be3de3131e34ea0` 对应的 ACR digest。`kup` 不需要 Docker，也不会重新 build/push 镜像。更新上游代码时，应先在 Galileo repo 重新完成 build、push 和 smoke，再一起更新 `GALILEO_SOURCE_COMMIT` 与 `GALILEO_IMAGE_REF`，禁止使用 `latest`。

运行期 Pod 只注入 Splunk AO、最终 application model 与 Pinecone 三个 key；VLLM Judge key、Docker Hub PAT、RAM AccessKey 和 ACR push credential 不会进入应用 Pod。若要展示四个 Qwen Evaluator 或 Experiment，需预先在 Splunk AO UI 中确认 Project、Agent Stream、Evaluator 与 Dataset；`kup` 不修改这些控制面对象。

还必须在私有 `kup.conf` 中手工增加：

```bash
ISO_REPO_URL="<authorized-enterprise-helm-repository>"
```

The Isovalent Enterprise Helm repository URL is intentionally omitted from kup.conf.example. Obtain it from an existing authorized Isovalent Enterprise configuration or the appropriate Cisco/Isovalent entitlement source, and add ISO_REPO_URL to the private kup.conf.

优先从已经工作的本地 AWS Demo 私有配置复制该值：

```text
/Users/hangwe/Library/CloudStorage/OneDrive-Cisco/dev/isovalent/aws/kup.conf
```

`kup.conf`、`kubeconfig`、Terraform state 与渲染文件均被 Git 忽略。两个入口会把私有配置设为 0600，生成的 kubeconfig 也固定为 0600。Galileo 的 Kubernetes Secret 通过 0600 临时文件创建并立即清除，不进入 `runtime/` 的持久文件。不要把私有值提交、复制到日志或合并进 `~/.kube/config`。

默认值已包含区域、CIDR、3 个 Worker、实例规格、磁盘、稳定 context、chart 版本、namespace 与本地端口。Standalone ClickHouse 请求 4 GiB 内存，因此默认 Worker 使用 4 vCPU/8 GiB 的 `ecs.e-c1m2.xlarge`；Galileo 只运行应用 Pod，不在 ACK 节点运行模型。节点镜像为支持 ACK 当前 cgroup v2 要求的 AliyunLinux3 Container Optimized。

## Create

```bash
./kup
```

创建通常需要较长时间。ACK Worker 在 Cilium 安装前显示 `NotReady` 是 BYOCNI 的预期行为；脚本先确认 Node 对象与 PodCIDR 已出现，再安装 Cilium，然后等待所有节点 `Ready`。

`kup` 是幂等的。第一次因 Ctrl-C、网络中断或临时镜像错误停止后，修复原因并再次运行 `./kup` 即可继续收敛；重复执行不会创建第二套 VPC 或 ACK 集群。Terraform 与 Helm 都有有限重试，Helm 命令返回后还会强制确认 release 为 `deployed`；中断留下的最新 `pending-*` revision 会在重试前精确移除，不会删除 workload 或任何 deployed revision。

脚本结束前会自动验证三节点 Ready/PodCIDR、Cilium health、Hubble flow export、Hubble Enterprise -> Timescape ingestion、所有应用 Pod Ready、DNS、pod-to-pod、pod-to-service、外部 HTTPS，以及每节点 Tetragon BPF LSM probe、network event、alert event、TracingPolicy 与 AlertRule。Galileo 还会验证 immutable image、ClusterIP HTTP、模型 DNS/TLS/认证与精确 model ID、Pinecone integrated text search，以及 Splunk AO HTTPS。任一硬检查失败都会返回非零状态。

自动化只使用：

```text
./kubeconfig
context: ack-byocni-demo
```

所有 Kubernetes/Helm 操作显式指定该文件和 context，不读取或改变全局 current-context，因此不会影响同一台 Mac 上的 AWS EKS context。

## Validate

先定义一个便于复制的只读 wrapper：

```bash
kctl() {
  kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo "$@"
}
```

ACK、PodCIDR 与节点状态：

```bash
kctl get nodes -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,PODCIDR:.spec.podCIDR,VERSION:.status.nodeInfo.kubeletVersion'
```

Cilium、Kubernetes IPAM、Native Routing、KPR 与 Hubble：

```bash
kctl -n kube-system get deployment/cilium-operator daemonset/cilium deployment/hubble-relay
kctl -n kube-system exec daemonset/cilium -c cilium-agent -- cilium-dbg status
kctl -n kube-system exec daemonset/cilium -c cilium-agent -- cilium-dbg config --all | grep -E 'routing-mode|ipam|kube-proxy-replacement'
```

Hubble Enterprise、Standalone Timescape/ClickHouse 与 Hubble UI：

```bash
helm --kubeconfig ./kubeconfig --kube-context ack-byocni-demo -n kube-system list
kctl -n kube-system get pods,svc,endpoints | grep -E 'hubble|timescape|clickhouse'
kctl -n kube-system logs -l app.kubernetes.io/instance=hubble-enterprise --tail=100 | grep -Ei 'error|failed' || true
```

Tetragon Agent、BPF LSM、policy 与日志目录：

```bash
kctl -n kube-system get daemonset/tetragon pods -l app.kubernetes.io/name=tetragon -o wide
kctl get tracingpolicies
kctl get alertrules
for p in $(kctl -n kube-system get pod -l app.kubernetes.io/component=agent,app.kubernetes.io/name=tetragon -o name); do
  kctl -n kube-system logs "$p" -c tetragon --tail=20000 | grep -F 'HaveProgramType(ebpf.LSM) = true'
  kctl -n kube-system exec "$p" -c tetragon -- sh -c \
    'test -s /var/run/cilium/hubble/tetragon.log && find /var/run/cilium/hubble/alert -type f -size +0 -print -quit | grep -q .'
done
```

当前 Tetragon chart 不会把 Host securityfs 挂入 Agent 容器，因此不能用容器内 `/sys/kernel/security/lsm` 是否存在来判断 Host BPF LSM。上面的 Agent feature probe 与非空 network/alert export 是 `kup` 使用的运行期硬检查。

mini-boutique、L7 policy 与 testcurl：

```bash
kctl -n demo get deployments,pods,services
kctl -n demo get ciliumnetworkpolicy demo-l7-visibility-no-block -o yaml
kctl -n test get daemonset/testcurl pods -o wide
TEST_POD=$(kctl -n test get pod -l app=testcurl -o jsonpath='{.items[0].metadata.name}')
kctl -n test exec "$TEST_POD" -- nslookup kubernetes.default.svc.cluster.local
kctl -n test exec "$TEST_POD" -- curl -fsS http://frontend.demo.svc.cluster.local/ >/dev/null
kctl -n test exec "$TEST_POD" -- curl -fsSI https://www.cisco.com/
```

Galileo multi-agent banking chatbot：

```bash
kctl -n galileo-demo get deployment,pods,service
kctl -n galileo-demo get deployment splunk-ao-banking-qwen \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
GALILEO_POD=$(kctl -n galileo-demo get pod \
  -l app.kubernetes.io/name=splunk-ao-banking-qwen -o json | \
  python3 -c 'import json,sys; p=json.load(sys.stdin)["items"]; print(next(x["metadata"]["name"] for x in p if not x["metadata"].get("deletionTimestamp") and any(c["type"] == "Ready" and c["status"] == "True" for c in x.get("status", {}).get("conditions", []))))')
kctl -n galileo-demo exec "$GALILEO_POD" -- python pod_network_smoke.py
kctl -n test exec "$TEST_POD" -- \
  curl -fsS http://splunk-ao-banking-qwen.galileo-demo.svc.cluster.local/ >/dev/null
```

## Hubble UI access

```bash
kubectl \
  --kubeconfig ./kubeconfig \
  --context ack-byocni-demo \
  -n kube-system \
  port-forward svc/hubble-ui 18080:80
```

打开 <http://127.0.0.1:18080>。Live 视图来自 Hubble Relay，Historical 视图来自 Standalone Timescape。无需也不应创建公网 UI LoadBalancer。

## Galileo banking chatbot demo

```bash
kubectl \
  --kubeconfig ./kubeconfig \
  --context ack-byocni-demo \
  -n galileo-demo \
  port-forward svc/splunk-ao-banking-qwen 8000:80
```

打开 <http://127.0.0.1:8000>。这是 Galileo repo 的 Chainlit/LangGraph Multi-agent banking chatbot baseline；Service 保持 ClusterIP，不创建 Ingress 或公网 LoadBalancer。

建议按以下顺序演示：

1. 新会话输入 `What is my credit score?`，重复 3–5 个独立会话，观察 supervisor 是否稳定转交 credit-score agent 并返回工具支持的 `550`。
2. 输入 `What are the cashback rewards offered by the Orbit Credit Card?`，预期 credit-card agent 使用 Pinecone，grounded answer 应说明 Orbit Basic 没有 cashback/rewards。
3. 输入 `Recommend me a good book.`，预期 supervisor 不调用银行业务 agent，并回答不知道或无法回答。
4. 在 Splunk AO 对应 Project/Agent Stream 中展开 supervisor、sub-agent、tool 与 model spans，对照 Action Advancement、Action Completion、Tool Errors、Tool Selection Quality 四个 Evaluator。

baseline 故意保留上游 supervisor prompt 的已知缺陷：它描述了 credit-card agent，却漏写已经存在的 credit-score agent。因此 credit-score 问题可能正确、只完成 handoff、或直接拒答；这种非确定性正是 Splunk AO Trace/Evaluation 演示内容。`kup` 不自动“修复” prompt，也不创建或修改 Splunk AO Evaluator/Dataset。完整演示与 Experiment 步骤以 [上游项目 README](https://github.com/highopes/galileo-demo) 为准。

## Destroy

```bash
./kiall
```

这是 disposable demo 的故意破坏性入口。它直接执行 `terraform destroy -auto-approve`，不先做 Helm uninstall、namespace 删除或 Kubernetes 优雅卸载。只有 destroy 成功且 `terraform state list` 为空时，脚本才删除项目私有 kubeconfig；Terraform state 文件本身保留。如果 destroy 失败，state 与 kubeconfig 都会保留，修复后再次运行 `./kiall`。Terraform destroy 最多有限重试三次；退出钩子确保中断或失败时保留的 kubeconfig 权限仍为 0600。

`kiall` 不扫描账号、区域或 VPC，也不会删除 state 外“看起来像 Demo”的资源。再次执行 `./kiall` 应安全显示没有资源需要销毁。

## Troubleshooting

### Terraform credential error

确认 `kup.conf` 中 RAM User AccessKey ID/Secret 正确、未过期且权限覆盖 ACK、ECS、VPC、NAT/SLB。Secret 无法找回时创建新 Key。不要把值贴入 issue 或日志。

### Provider download error

确认 Mac 能访问 Terraform Registry，然后重试 `./kup`。代理环境需让 Terraform/Go 下载使用同一代理；不要提交 `.terraform/`。

### ACK workers initially NotReady

这是 BYOCNI 在 Cilium 安装前的正常状态。只有 Node 对象未出现或 `.spec.podCIDR` 为空超过脚本超时时间才是错误。查看 ACK Node Pool 事件与 ECS 初始化日志。

### Cilium ImagePullBackOff

中国大陆访问外部 registry 可能受限。检查 Pod events；需要时通过已授权 ACR 订阅/镜像同步或企业允许的加速方案解决，不要改成 Terway chaining，也不要随意替换 Enterprise 镜像。

### Cilium Agent not Ready

检查 `daemonset/cilium` events 和 agent 日志，确认节点 PodCIDR、VPC 路由、`securityContext.privileged`、Kubernetes IPAM 与 native routing CIDR 一致。再次运行 `./kup` 会继续 Helm 收敛。

### BPF LSM not enabled

节点首次启动会通过 `user_data` 用 `grubby` 追加 `bpf` 并安排一次重启。检查节点 cloud-init/journal 中的 `ack-byocni-bpf-lsm` 日志。marker 防止重复修改和 reboot loop；如果内核本身不支持 BPF LSM，应更换受支持的 AliyunLinux3 镜像/规格。

### Timescape ClickHouse Pending or OOM

查看 Pod events 与节点 allocatable memory。基线 ClickHouse 请求 4 GiB 且使用 ephemeral storage；不要创建 PVC。默认 `ecs.e-c1m2.xlarge` 为此预留空间。如区域库存不足，选择同区域可用、至少 8 GiB 内存的等效实例。

### Hubble Enterprise to Timescape push error

确认 `hubble-timescape-ingester` endpoints 非空，并检查 Hubble Enterprise fluentd 日志。目标应为 `http://hubble-timescape-ingester.kube-system.svc.cluster.local:4260/push`；不要加入 Integrated Timescape 的 `k8sImporter` values。

### Hubble UI cannot access Timescape

确认 `hubble-ui`、`hubble-relay`、`hubble-timescape` Service 都有 ready endpoints。UI 的 Timescape 地址应为 `hubble-timescape.kube-system.svc.cluster.local`，Relay 地址应为 `hubble-relay.kube-system.svc.cluster.local`。

### Tetragon BTF/LSM issue

确认 `/sys/kernel/btf/vmlinux` 存在，`/sys/kernel/security/lsm` 包含 `bpf`，运行时是 containerd 且 socket 位于 `/run/containerd/containerd.sock`。检查 Tetragon Agent 日志中的 verifier、BTF、LSM 或 permission 错误。

### Alibaba image pull issue

mini-boutique 与 testcurl 已使用 Alibaba Registry 镜像。若仍失败，检查目标 registry 的区域连通、镜像 tag 与 ACK 节点 NAT 出口；不要默认改用 AWS Demo 的 quay.io workload。

### Galileo ImagePullBackOff

确认 `GALILEO_IMAGE_REF` 是 `GALILEO_REGISTRY_SERVER` 下的完整 `@sha256:` immutable reference，并确认 ACR pull username/password 有目标 repository 权限。`kup` 每次都会重建 `galileo-registry-pull` Secret，但不会创建 ACR instance、namespace 或 repository，也不会回退到 `latest`。

### Galileo model, Pinecone, or Splunk AO check fails

`kup` 会在应用 Pod 内运行上游 `pod_network_smoke.py`。模型检查要求 HTTPS `/models` 可认证访问且返回精确 `GALILEO_APP_MODEL_NAME`；Pinecone 检查要求隔离 index/namespace 对 Orbit 查询至少返回一个 hit；Splunk AO console 必须能建立 HTTPS 连接。修复 `kup.conf` 中对应 endpoint/key 或外部服务状态后重跑 `./kup`，不要跳过该硬检查。

### Interrupted kup

保留 Terraform state、kubeconfig 与 `runtime/`，修复中断原因后再次运行 `./kup`。不要手工新建第二套 ACK/VPC。

### Interrupted kiall

不要删除 state。确认上一次 Terraform 操作已停止后再次运行 `./kiall`。脚本只会重试当前 state 的 destroy；失败时不会执行激进清理。

Cloud Shell 仅可在极端情况下作为 Alibaba 侧诊断工具，不属于正常 create/destroy 流程，也不用于手工复制 kubeconfig。

## Roadmap / Deferred Features

以下功能故意不属于 baseline `kup`：

- Observability：kube-prometheus-stack、Grafana、Cilium/Hubble/Tetragon dashboards。
- Application demo：OpenTelemetry Demo。Alibaba Cloud Internet/image accessibility requires a separately verified deployment strategy.
- Egress Gateway：Egress Gateway、HA、external echo/remote outpost 与 failover demo。
- Splunk：Universal Forwarder、Tetragon/Alert 到 Splunk；不会复制 AWS SSM implementation。
- Security attack demo：Vulhub、Shiro 1.2.4、reverse shell、brute-force target 与其他 victim workload。Deferred intentionally; not part of baseline kup.
- Advanced Tetragon：custom Java base64 pipe-to-shell policy、throughput policy、FIM、filesystem SCA、Application Model 与 advanced enforcement。
- AWS-specific：EKS ENI IPAM、AWS SSM、EC2 Security Group 自动配置、CloudFormation cleanup、AWS remote-outpost EC2。

## Cost and security

`destroy means destroy`：Terraform 管理 ACK、Worker、VPC、vSwitch，以及 ACK 创建的 NAT/公网 API 依赖；`kiall` 通过同一 state 删除它们，Galileo namespace 也随 ACK 集群一起消失。Timescape 使用 ephemeral Lite，不创建 PVC；Hubble UI 与 Galileo 都使用 ClusterIP。运行 Demo 会产生 Alibaba Cloud 费用，调用应用模型、Pinecone 与 Splunk AO 还可能产生各服务侧用量或费用；不使用时执行 `./kiall`。

本仓库用于内部演示与自动化实验。使用 Isovalent Enterprise chart 与镜像时遵守相应 entitlement、许可与组织安全要求。
