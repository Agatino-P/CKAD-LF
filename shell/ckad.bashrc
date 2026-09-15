# Exam-speed kubectl shortcuts for bash (the exam terminal is bash).
# Load into the current shell with:  source shell/ckad.bashrc
alias k=kubectl
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
export do='--dry-run=client -o yaml'   # k run web --image=nginx $do > pod.yaml
export now='--grace-period=0 --force'  # k delete pod web $now
