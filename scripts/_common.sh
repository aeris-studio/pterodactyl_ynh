#!/bin/bash

#=================================================
# COMMON VARIABLES
#=================================================

# dependencies used by the app
pkg_dependencies="software-properties-common dirmngr"

#=================================================
# PERSONAL HELPERS
#=================================================

#=================================================
# EXPERIMENTAL HELPERS
#=================================================
# Execute a command with Composer
#
# usage: ynh_composer_exec --phpversion=phpversion [--workdir=$final_path] --commands="commands"
# | arg: -w, --workdir - The directory from where the command will be executed. Default $final_path.
# | arg: -c, --commands - Commands to execute.
ynh_composer_exec () {
	# Declare an array to define the options of this helper.
	local legacy_args=vwc
	declare -Ar args_array=( [v]=phpversion= [w]=workdir= [c]=commands= )
	local phpversion
	local workdir
	local commands
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"
	workdir="${workdir:-$final_path}"
	phpversion="${phpversion:-7.0}"

	COMPOSER_HOME="$workdir/.composer" \
		php${phpversion} "$workdir/composer.phar" $commands \
		-d "$workdir" --quiet --no-interaction
}

# Install and initialize Composer in the given directory
#
# usage: ynh_install_composer --phpversion=phpversion [--workdir=$final_path]
# | arg: -w, --workdir - The directory from where the command will be executed. Default $final_path.
ynh_install_composer () {
	# Declare an array to define the options of this helper.
	local legacy_args=vw
	declare -Ar args_array=( [v]=phpversion= [w]=workdir= )
	local phpversion
	local workdir
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"
	workdir="${workdir:-$final_path}"
	phpversion="${phpversion:-7.0}"

	curl -sS https://getcomposer.org/installer \
		| COMPOSER_HOME="$workdir/.composer" \
		php${phpversion} -- --quiet --install-dir="$workdir" \
		|| ynh_die "Unable to install Composer."

	# update dependencies to create composer.lock
	ynh_composer_exec --phpversion="${phpversion}" --workdir="$workdir" --commands="install --no-dev" \
		|| ynh_die "Unable to update core dependencies with Composer."
}


# Create a dedicated php-fpm config
#
# usage 1: ynh_add_fpm_config [--phpversion=7.X] [--use_template]
# | arg: -v, --phpversion - Version of php to use.
# | arg: -t, --use_template - Use this helper in template mode.
#
# -----------------------------------------------------------------------------
#
# usage 2: ynh_add_fpm_config [--phpversion=7.X] --usage=usage --footprint=footprint
# | arg: -v, --phpversion - Version of php to use.#
# | arg: -f, --footprint      - Memory footprint of the service (low/medium/high).
# low    - Less than 20Mb of ram by pool.
# medium - Between 20Mb and 40Mb of ram by pool.
# high   - More than 40Mb of ram by pool.
# Or specify exactly the footprint, the load of the service as Mb by pool instead of having a standard value.
# To have this value, use the following command and stress the service.
# watch -n0.5 ps -o user,cmd,%cpu,rss -u APP
#
# | arg: -u, --usage     - Expected usage of the service (low/medium/high).
# low    - Personal usage, behind the sso.
# medium - Low usage, few people or/and publicly accessible.
# high   - High usage, frequently visited website.
#
# Requires YunoHost version 2.7.2 or higher.
ynh_add_fpm_config () {
	# Declare an array to define the options of this helper.
	local legacy_args=vtuf
	declare -Ar args_array=( [v]=phpversion= [t]=use_template [u]=usage= [f]=footprint= )
	local phpversion
	local use_template
	local usage
	local footprint
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"

	# The default behaviour is to use the template.
	use_template="${use_template:-1}"
	usage="${usage:-}"
	footprint="${footprint:-}"
	if [ -n "$usage" ] || [ -n "$footprint" ]; then
		use_template=0
	fi

	# Configure PHP-FPM 7.0 by default
	phpversion="${phpversion:-7.0}"

	local fpm_config_dir="/etc/php/$phpversion/fpm"
	local fpm_service="php${phpversion}-fpm"
	# Configure PHP-FPM 5 on Debian Jessie
	if [ "$(ynh_get_debian_release)" == "jessie" ]; then
		fpm_config_dir="/etc/php5/fpm"
		fpm_service="php5-fpm"
	fi
	ynh_app_setting_set --app=$app --key=fpm_config_dir --value="$fpm_config_dir"
	ynh_app_setting_set --app=$app --key=fpm_service --value="$fpm_service"
	finalphpconf="$fpm_config_dir/pool.d/$app.conf"
	ynh_backup_if_checksum_is_different --file="$finalphpconf"

	if [ $use_template -eq 1 ]
	then
        # Usage 1, use the template in ../conf/php-fpm.conf
                cp ../conf/php-fpm.conf "$finalphpconf"
                ynh_replace_string --match_string="__NAMETOCHANGE__" --replace_string="$app" --target_file="$finalphpconf"
                ynh_replace_string --match_string="__FINALPATH__" --replace_string="$final_path" --target_file="$finalphpconf"
                ynh_replace_string --match_string="__USER__" --replace_string="$app" --target_file="$finalphpconf"
                ynh_replace_string --match_string="__PHPVERSION__" --replace_string="$phpversion" --target_file="$finalphpconf"

	else
        # Usage 2, generate a php-fpm config file with ynh_get_scalable_phpfpm
                ynh_get_scalable_phpfpm --usage=$usage --footprint=$footprint

                # Copy the default file
                cp "$fpm_config_dir/pool.d/www.conf" "$finalphpconf"

                # Replace standard variables into the default file
                ynh_replace_string --match_string="^\[www\]" --replace_string="[$app]" --target_file="$finalphpconf"
                ynh_replace_string --match_string=".*listen = .*" --replace_string="listen = /var/run/php/php$phpversion-fpm-$app.sock" --target_file="$finalphpconf"
                ynh_replace_string --match_string="^user = .*" --replace_string="user = $app" --target_file="$finalphpconf"
                ynh_replace_string --match_string="^group = .*" --replace_string="group = $app" --target_file="$finalphpconf"
                ynh_replace_string --match_string=".*chdir = .*" --replace_string="chdir = $final_path" --target_file="$finalphpconf"

                # Configure fpm children
                ynh_replace_string --match_string=".*pm = .*" --replace_string="pm = $php_pm" --target_file="$finalphpconf"
                ynh_replace_string --match_string=".*pm.max_children = .*" --replace_string="pm.max_children = $php_max_children" --target_file="$finalphpconf"
                ynh_replace_string --match_string=".*pm.max_requests = .*" --replace_string="pm.max_requests = 500" --target_file="$finalphpconf"
                ynh_replace_string --match_string=".*request_terminate_timeout = .*" --replace_string="request_terminate_timeout = 1d" --target_file="$finalphpconf"
                if [ "$php_pm" = "dynamic" ]
                then
			ynh_replace_string --match_string=".*pm.start_servers = .*" --replace_string="pm.start_servers = $php_start_servers" --target_file="$finalphpconf"
			ynh_replace_string --match_string=".*pm.min_spare_servers = .*" --replace_string="pm.min_spare_servers = $php_min_spare_servers" --target_file="$finalphpconf"
			ynh_replace_string --match_string=".*pm.max_spare_servers = .*" --replace_string="pm.max_spare_servers = $php_max_spare_servers" --target_file="$finalphpconf"
		elif [ "$php_pm" = "ondemand" ]
		then
			ynh_replace_string --match_string=".*pm.process_idle_timeout = .*" --replace_string="pm.process_idle_timeout = 10s" --target_file="$finalphpconf"
		fi

		# Comment unused parameters
		if [ "$php_pm" != "dynamic" ]
		then
			ynh_replace_string --match_string=".*\(pm.start_servers = .*\)" --replace_string=";\1" --target_file="$finalphpconf"
			ynh_replace_string --match_string=".*\(pm.min_spare_servers = .*\)" --replace_string=";\1" --target_file="$finalphpconf"
			ynh_replace_string --match_string=".*\(pm.max_spare_servers = .*\)" --replace_string=";\1" --target_file="$finalphpconf"
		fi
		if [ "$php_pm" != "ondemand" ]
		then
			ynh_replace_string --match_string=".*\(pm.process_idle_timeout = .*\)" --replace_string=";\1" --target_file="$finalphpconf"
		fi

		# Concatene the extra config.
		if [ -e ../conf/extra_php-fpm.conf ]; then
			cat ../conf/extra_php-fpm.conf >> "$finalphpconf"
		fi
	fi


	
	chown root: "$finalphpconf"
	ynh_store_file_checksum --file="$finalphpconf"

	if [ -e "../conf/php-fpm.ini" ]
	then
		echo "Packagers ! Please do not use a separate php ini file, merge your directives in the pool file instead." >&2
		finalphpini="$fpm_config_dir/conf.d/20-$app.ini"
		ynh_backup_if_checksum_is_different "$finalphpini"
		cp ../conf/php-fpm.ini "$finalphpini"
		chown root: "$finalphpini"
		ynh_store_file_checksum "$finalphpini"
	fi

	ynh_systemd_action --service_name=$fpm_service --action=reload
}

# Remove the dedicated php-fpm config
#
# usage: ynh_remove_fpm_config
#
# Requires YunoHost version 2.7.2 or higher.
ynh_remove_fpm_config () {
	local fpm_config_dir=$(ynh_app_setting_get --app=$app --key=fpm_config_dir)
	local fpm_service=$(ynh_app_setting_get --app=$app --key=fpm_service)
	# Assume php version 7 if not set
	if [ -z "$fpm_config_dir" ]; then
		fpm_config_dir="/etc/php/7.0/fpm"
		fpm_service="php7.0-fpm"
	fi
	ynh_secure_remove --file="$fpm_config_dir/pool.d/$app.conf"
	ynh_secure_remove --file="$fpm_config_dir/conf.d/20-$app.ini" 2>&1
	ynh_systemd_action --service_name=$fpm_service --action=reload
}

# Install another version of php.
#
# usage: ynh_install_php --phpversion=phpversion [--package=packages]
# | arg: -v, --phpversion - Version of php to install.
# | arg: -p, --package - Additionnal php packages to install
ynh_install_php () {
	# Declare an array to define the options of this helper.
	local legacy_args=vp
	declare -Ar args_array=( [v]=phpversion= [p]=package= )
	local phpversion
	local package
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"
	package=${package:-}

	# Store phpversion into the config of this app
	ynh_app_setting_set $app phpversion $phpversion

	if [ "$phpversion" == "7.0" ]
	then
		ynh_die "Do not use ynh_install_php to install php7.0"
	fi

	# Store the ID of this app and the version of php requested for it
	echo "$YNH_APP_INSTANCE_NAME:$phpversion" | tee --append "/etc/php/ynh_app_version"

	# Add an extra repository for those packages
	ynh_install_extra_repo --repo="https://packages.sury.org/php/ $(lsb_release -sc) main" --key="https://packages.sury.org/php/apt.gpg" --priority=995 --name=extra_php_version

	# Install requested dependencies from this extra repository.
	# Install php-fpm first, otherwise php will install apache as a dependency.
	ynh_add_app_dependencies --package="php${phpversion}-fpm"
	ynh_add_app_dependencies --package="php$phpversion php${phpversion}-common $package"

	# Set php7.0 back as the default version for php-cli.
	update-alternatives --set php /usr/bin/php7.0

	# Pin this extra repository after packages are installed to prevent sury of doing shit
	ynh_pin_repo --package="*" --pin="origin \"packages.sury.org\"" --priority=200 --name=extra_php_version
	ynh_pin_repo --package="php7.0*" --pin="origin \"packages.sury.org\"" --priority=600 --name=extra_php_version --append

	# Advertise service in admin panel
	yunohost service add php${phpversion}-fpm --log "/var/log/php${phpversion}-fpm.log"
}

# Remove the specific version of php used by the app.
#
# usage: ynh_install_php
ynh_remove_php () {
	# Get the version of php used by this app
	local phpversion=$(ynh_app_setting_get $app phpversion)

	if [ "$phpversion" == "7.0" ] || [ -z "$phpversion" ]
	then
		if [ "$phpversion" == "7.0" ]
		then
			ynh_print_err "Do not use ynh_remove_php to install php7.0"
		fi
		return 0
	fi

	# Remove the line for this app
	sed --in-place "/$YNH_APP_INSTANCE_NAME:$phpversion/d" "/etc/php/ynh_app_version"

	# If no other app uses this version of php, remove it.
	if ! grep --quiet "$phpversion" "/etc/php/ynh_app_version"
	then
		# Purge php dependences for this version.
		ynh_package_autopurge "php$phpversion php${phpversion}-fpm php${phpversion}-common"
		# Remove the service from the admin panel
		yunohost service remove php${phpversion}-fpm
	fi

	# If no other app uses alternate php versions, remove the extra repo for php
	if [ ! -s "/etc/php/ynh_app_version" ]
	then
		ynh_secure_remove /etc/php/ynh_app_version
	fi
}
#=================================================
# FUTURE OFFICIAL HELPERS
#=================================================

