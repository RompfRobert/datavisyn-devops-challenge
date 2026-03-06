```bash
cd terraform; terraform apply -auto-approve; cd ..
```

```bash
helm upgrade --install backend ./helm/backend -n demo --create-namespace
helm upgrade --install frontend ./helm/frontend -n demo
```

```bash
kubectl get pods,svc -n demo
```

```bash
kubectl port-forward svc/frontend 8080:80 -n demo
```

```bash
kubectl port-forward svc/backend 8081:80 -n demo
```

```bash

```

```bash

```
