# fogstack

fogstack là nền tảng endpoint AWS cục bộ cho các dự án cá nhân. Nó khởi động
một cụm Kubernetes, registry, cơ sở dữ liệu Postgres và các dịch vụ tùy chọn
tương thích AWS ngay trong phạm vi repo, để ứng dụng có thể trỏ vào endpoint
cục bộ mà không chạm tới kube context của công ty hoặc credential AWS thật.

## Hợp đồng endpoint

| Endpoint | Profile | Vai trò | Backend |
|---|---|---|---|
| `KUBECONFIG=<repo>/.state/kubeconfig.yaml` | minimal, full | Mục tiêu Kubernetes kiểu EKS | kind + cloud-provider-kind |
| `localhost:5001` | minimal, full | Registry image kiểu ECR | registry |
| `localhost:5432` | minimal, full | Postgres kiểu RDS | postgres |
| `http://localhost:4566` | full | Bề mặt AWS API cho S3, SQS, IAM, Lambda và các dịch vụ liên quan | Floci |
| `http://localhost:9200` | full | OpenSearch API | OpenSearch |
| `http://localhost:5601` | full | OpenSearch Dashboards | OpenSearch Dashboards |

Mọi lệnh đều bảo vệ máy host trước: Kubernetes ghi vào
`.state/kubeconfig.yaml`, các file cấu hình AWS trỏ vào `.state/`, và
credential cục bộ giả được export cho riêng tiến trình. Stack không cần
`~/.kube` hoặc `~/.aws`.

## Bắt đầu nhanh

Yêu cầu trước khi chạy: Docker Desktop với ít nhất 8 GB cấp cho Docker VM, cùng
các binary trên host gồm `kind`, `kubectl`, `helm`, `terraform`, và `curl`.
Toolbox image cung cấp các client tool được pin version để kiểm tra lặp lại
ổn định, nhưng các lệnh stack chính hiện chạy trên host.

```bash
git clone <repo-url> fogstack
cd fogstack
cp .env.example .env
./engine/fog doctor
./engine/fog up
eval "$(./engine/fog endpoints)"
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" get nodes
./engine/fog status
```

Tự kiểm tra tùy chọn:

```bash
checks/smoke.sh
```

Để thử AWS API, dùng full profile:

```bash
./engine/fog up --profile full
eval "$(./engine/fog endpoints --profile full)"
aws --endpoint-url "$AWS_ENDPOINT_URL" s3 ls
```

## Profile

| Profile | Khởi động | Bộ nhớ Docker VM đề xuất | Khi nào dùng |
|---|---|---:|---|
| `minimal` | kind, local registry, Postgres, plumbing cho sample app | 8 GB | Khi bạn cần Kubernetes, image và Postgres thật nhanh. |
| `full` | mọi thứ trong `minimal`, cộng thêm Floci, OpenSearch, Dashboards, Gateway API routing và log shipping | Tối thiểu 8 GB, nhiều hơn sẽ mượt hơn | Khi bạn cần API tương thích AWS hoặc observability. |

`fog up` mặc định dùng `minimal`. Chỉ dùng `--profile full` khi dự án của bạn
cần endpoint tương thích AWS hoặc OpenSearch.

## Dùng với dự án của bạn

Chạy lệnh này trong shell sau khi stack đã healthy:

```bash
eval "$(./engine/fog endpoints)"
```

Terraform: tạo local provider override cho một thư mục thử nghiệm:

```bash
./engine/fog tf-init path/to/terraform
```

SDK và AWS CLI: luôn truyền endpoint rõ ràng. Ví dụ:

```bash
aws --endpoint-url "$AWS_ENDPOINT_URL" s3 ls
```

Kubernetes và Helm: dùng kubeconfig và context nằm trong repo:

```bash
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" get pods -A
helm --kubeconfig "$KUBECONFIG" --kube-context "$KUBE_CONTEXT" list -A
```

Postgres:

```bash
psql "$POSTGRES_URL"
```

Registry:

```bash
docker build -t "$REGISTRY/my-app:dev" .
docker push "$REGISTRY/my-app:dev"
```

Toolbox đã pin version:

```bash
./engine/fog-toolbox --build
./engine/fog-toolbox terraform version
```

## Giới hạn

Các API VPC và security group hữu ích cho workflow tạo/đọc/cập nhật/xóa, nhưng
chúng không thực thi network policy thật. IAM chấp nhận các luồng phát triển
cục bộ, nhưng không phải là ranh giới phân quyền thật. Emulator tương thích AWS
còn trẻ và có thể thay đổi nhanh hơn chính AWS.

Không dùng fogstack như môi trường kiểm thử tương đương production. Nó dành cho
vòng phản hồi phát triển cục bộ, nối dây tích hợp, và học hình dạng của các
workflow gần AWS trước khi tiêu tiền cloud.

## Kiến trúc

```text
host shell
  |
  | eval "$(engine/fog endpoints)"
  v
.state/kubeconfig.yaml       localhost:5001        localhost:5432
      |                            |                    |
      v                            v                    v
   kind cluster  <-------- local registry -------->  Postgres
      |
      +-- sample app, Gateway API, cloud-provider-kind
      |
      +-- full profile service aliases
              |                  |
              v                  v
        Floci AWS API       OpenSearch
```

`engine/fog down --volumes` xóa các container của stack, cụm kind, volume cục bộ
và các container load balancer thuộc fogstack.

## Xử lý sự cố

Port đã được dùng: chạy `./engine/fog doctor`. Nếu port thuộc về một container
fogstack, quá trình startup có thể tiếp tục; nếu process khác đang giữ port,
dừng process đó hoặc đổi port liên quan trong `.env`.

Bộ nhớ Docker quá nhỏ: tăng bộ nhớ Docker Desktop lên ít nhất 8 GB và chạy lại
`./engine/fog doctor`.

Cluster chưa sẵn sàng: chạy `./engine/fog down --volumes`, rồi chạy lại
`./engine/fog up`. Nếu vẫn lỗi, kiểm tra `docker ps` và `kind get clusters`.

Không có endpoint load balancer: đợi thêm một phút, rồi kiểm tra container cloud
provider bằng `docker logs fogstack-cloud-provider-kind`.

Thiếu endpoint full profile: xác nhận bạn đã khởi động bằng `./engine/fog up
--profile full` và đã eval `./engine/fog endpoints --profile full`.

Gỡ cài đặt:

```bash
./engine/fog down --volumes
rm -rf .state
docker image rm "fogstack-toolbox:$(awk -F= '$1==\"FOGSTACK_VERSION\"{print $2}' versions.env)" 2>/dev/null || true
```

## Giấy phép và ghi công

fogstack được phát hành theo MIT License. Xem [LICENSE](LICENSE).

Ghi công: Floci cho backend API tương thích AWS, kind cho Kubernetes cục bộ,
cloud-provider-kind cho hành vi load balancer cục bộ, Envoy Gateway cho Gateway
API routing, OpenSearch cho tìm kiếm/kiểm tra log cục bộ, PostgreSQL, Terraform,
Helm, kubectl, Docker, ShellCheck và Hadolint.
