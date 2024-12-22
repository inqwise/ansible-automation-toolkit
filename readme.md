# 🛠️ **Ansible Automation Toolkit**

## 🚀 **Overview**

The **Ansible Automation Toolkit** is a collection of Ansible playbooks, configuration files, and shell scripts designed to simplify and automate cloud infrastructure management tasks, primarily on **AWS (Amazon Web Services)**. The toolkit focuses on managing resources like EC2 instances, AMIs, S3 buckets, and Autoscaling groups while supporting multiple operating system environments, including **Amazon Linux 2** and **Amazon Linux 2023**.

---

## 📦 **Key Features**

- **Infrastructure Automation:** Automate the creation, management, and cleanup of AWS resources.
- **OS Compatibility:** Supports Amazon Linux 2, Amazon Linux 2023, and other Linux distributions.
- **Modular Design:** Individual playbooks and scripts for specific tasks.
- **Scalability:** Integrated with AWS Autoscaling and resource optimization tools.
- **Reusable Templates:** Build consistent environments with reusable templates.
- **CI/CD Integration:** Workflow support via `.github` configurations.

---

## 📂 **Project Structure**

```plaintext
.
├── ami/                   # AMI management resources
├── autoscaling/           # Autoscaling configurations
├── packer/                # Packer templates for image creation
├── s3/                    # AWS S3 configurations
├── scripts/               # General-purpose scripts
├── access.yml             # Access configuration
├── main.yml               # Main Ansible playbook
├── requirements.txt       # Python dependencies
├── requirements_amzn2.yml # Dependencies for Amazon Linux 2
├── requirements_amzn2023.yml # Dependencies for Amazon Linux 2023
├── create_template.sh     # Script to create templates
├── cleanup_template.sh    # Script to clean templates
├── userdata.sh            # User data script for EC2 instances
└── identify_os.sh         # Script to detect operating systems

⚙️ Scripts Overview
	•	create_template.sh: Creates infrastructure templates.
	•	cleanup_template.sh: Cleans specific templates.
	•	cleanup_test_dns_records.sh: Cleans test DNS records.
	•	terminate_test_instances.sh: Terminates AWS test instances.
	•	userdata.sh: Configures EC2 instances during boot.

📖 Configuration Files
	•	access.yml: Manages permissions and access controls.
	•	main.yml: Core Ansible playbook for orchestration.
	•	requirements.yml: Dependency management files for different environments.

🏗️ Supported Operating Systems
	•	Amazon Linux 2
	•	Amazon Linux 2023
	•	Other Linux distributions (with proper configuration)

🤝 Contributing

We welcome contributions! Please follow these steps:
	1.	Fork the repository.
	2.	Create a feature branch:

git checkout -b feature-new-feature


	3.	Commit your changes:

git commit -m "Add new feature"


	4.	Push to the branch:

git push origin feature-new-feature


	5.	Open a Pull Request.

📜 License

This project is licensed under the MIT License. See the LICENSE file for details.

🛟 Support
	•	Open an issue on GitHub Issues
	•	For direct queries, contact the repository maintainers.

🌟 Acknowledgments

Special thanks to all contributors and the open-source community for making this project possible.

Let me know if you'd like further refinements or additional sections added! 🚀✨