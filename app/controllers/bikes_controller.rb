class OwnershipNotSavedError < StandardError
end

class BikeUpdatorError < StandardError
end

class BikesController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:create]
  before_action :sign_in_if_not!, only: [:show]
  before_action :find_bike, only: [:show, :edit, :update, :pdf, :resolve_token]
  before_action :ensure_user_allowed_to_edit, only: [:edit, :update, :pdf]
  before_action :render_ad, only: [:index, :show]
  before_action :remove_subdomain, only: [:index]
  before_action :assign_current_organization, only: [:index, :show, :edit]

  def index
    @interpreted_params = Bike.searchable_interpreted_params(permitted_search_params, ip: forwarded_ip_address)
    @stolenness = @interpreted_params[:stolenness]

    if params[:stolenness] == "proximity" && @stolenness != "proximity"
      flash[:info] = translation(:we_dont_know_location, location: params[:location])
    end

    @bikes = Bike.search(@interpreted_params).page(params[:page] || 1).per(params[:per_page] || 10).decorate
    @selected_query_items_options = Bike.selected_query_items_options(@interpreted_params)
  end

  def show
    @components = @bike.components
    if @bike.current_stolen_record.present?
      # Show contact owner box on load - happens if user has clicked on it and then logged in
      @contact_owner_open = @bike.contact_owner?(current_user) && params[:contact_owner].present?
      @stolen_record = @bike.current_stolen_record
    end
    if current_user.present? && BikeDisplayer.display_impound_claim?(@bike, current_user)
      impound_claims = @bike.impound_claims_claimed.where(user_id: current_user.id)
      @contact_owner_open = params[:contact_owner].present?
      @impound_claim = impound_claims.unsubmitted.last
      @impound_claim ||= @bike.impound_claims_submitting.where(user_id: current_user.id).last
      @impound_claim ||= @bike.current_impound_record&.impound_claims&.build
      @submitted_impound_claims = impound_claims.where.not(id: @impound_claim.id).submitted
    end
    # These ivars are here primarily to make testing possible
    @passive_organization_registered = passive_organization.present? && @bike.organized?(passive_organization)
    @passive_organization_authorized = passive_organization.present? && @bike.authorized_by_organization?(org: passive_organization)
    @bike = @bike.decorate
    if params[:scanned_id].present?
      @bike_sticker = BikeSticker.lookup_with_fallback(params[:scanned_id], organization_id: params[:organization_id], user: current_user)
    end
    find_token
    respond_to do |format|
      format.html { render :show }
      format.gif { render qrcode: bike_url(@bike), level: :h, unit: 50 }
    end
  end

  def pdf
    if @bike.current_stolen_record.present?
      @stolen_record = @bike.current_stolen_record
    end
    @bike = @bike.decorate
    filename = "Registration_" + @bike.updated_at.strftime("%m%d_%H%M")[0..]
    unless @bike.pdf.present? && @bike.pdf.file.filename == "#{filename}.pdf"
      pdf = render_to_string pdf: filename, template: "bikes/pdf"
      save_path = "#{Rails.root}/tmp/#{filename}.pdf"
      File.open(save_path, "wb") do |file|
        file << pdf
      end
      # @bike.pdf = File.open(pdf, 'wb') { |file| file << pdf }
      @bike.pdf = File.open(save_path)
      @bike.save
    end
    # render pdf: 'registration_pdf', show_as_html: true
    redirect_to @bike.pdf.url
  end

  def scanned
    @bike_sticker = BikeSticker.lookup_with_fallback(scanned_id, organization_id: params[:organization_id], user: current_user)
    if @bike_sticker.blank?
      flash[:error] = translation(:unable_to_find_sticker, scanned_id: params[:scanned_id])
      redirect_to user_root_url
    elsif @bike_sticker.bike.present?
      redirect_to(bike_url(@bike_sticker.bike_id, scanned_id: params[:scanned_id], organization_id: params[:organization_id])) && return
    elsif current_user.present?
      @page = params[:page] || 1
      @per_page = params[:per_page] || 25
      if current_user.member_of?(@bike_sticker.organization)
        set_passive_organization(@bike_sticker.organization)
        redirect_to(organization_bikes_path(organization_id: passive_organization.to_param, bike_sticker: @bike_sticker.code)) && return
      else
        @bikes = current_user.bikes.reorder(created_at: :desc).limit(100)
      end
    end
  end

  def spokecard
    @qrcode = "#{bike_url(Bike.find(params[:id]))}.gif"
    render layout: false
  end

  def new
    unless current_user.present?
      store_return_to(new_bike_path(b_param_token: params[:b_param_token], stolen: params[:stolen]))
      flash[:info] = translation(:please_sign_in_to_register)
      redirect_to(new_user_path) && return
    end
    find_or_new_b_param
    redirect_to(bike_path(@b_param.created_bike_id)) && return if @b_param.created_bike.present?
    # Let them know if they sent an invalid b_param token - use flash#info rather than error because we're aggressive about removing b_params
    flash[:info] = translation(:we_couldnt_find_that_registration) if @b_param.id.blank? && params[:b_param_token].present?
    @bike ||= BikeCreator.new(@b_param).build_bike(BParam.bike_attrs_from_url_params(params.permit(:status, :stolen).to_h))
    # Fallback to active (i.e. passed organization_id), then passive_organization
    @bike.creation_organization ||= current_organization || passive_organization
    @organization = @bike.creation_organization
    @page_errors = @b_param.bike_errors
  end

  def create
    find_or_new_b_param
    if params[:bike][:embeded] # NOTE: if embeded, doesn't verify csrf token
      if @b_param.created_bike.present?
        redirect_to edit_bike_url(@b_param.created_bike)
      end
      if params[:bike][:image].present? # Have to do in the controller, before assigning
        @b_param.image = params[:bike].delete(:image) if params.dig(:bike, :image).present?
      end
      @b_param.update_attributes(params: permitted_bparams,
                                 origin: (params[:bike][:embeded_extended] ? "embed_extended" : "embed"))
      @bike = BikeCreator.new(@b_param, location: request.safe_location).create_bike
      if @bike.errors.any?
        flash[:error] = @b_param.bike_errors.to_sentence
        if params[:bike][:embeded_extended]
          redirect_to(embed_extended_organization_url(id: @bike.creation_organization.slug, b_param_id_token: @b_param.id_token)) && return
        else
          redirect_to(embed_organization_url(id: @bike.creation_organization.slug, b_param_id_token: @b_param.id_token)) && return
        end
      elsif params[:bike][:embeded_extended]
        flash[:success] = translation(:bike_was_sent_to, bike_type: @bike.type, owner_email: @bike.owner_email)
        @persist_email = ParamsNormalizer.boolean(params[:persist_email])
        redirect_to(embed_extended_organization_url(@bike.creation_organization, email: @persist_email ? @bike.owner_email : nil)) && return
      else
        redirect_to(controller: :organizations, action: :embed_create_success, id: @bike.creation_organization.slug, bike_id: @bike.id) && return
      end
    elsif verified_request?
      if @b_param.created_bike.present?
        redirect_to(edit_bike_url(@b_param.created_bike)) && return
      end
      @b_param.clean_params(permitted_bparams)
      @bike = BikeCreator.new(@b_param).create_bike
      if @bike.errors.any?
        redirect_to new_bike_url(b_param_token: @b_param.id_token)
      else
        flash[:success] = translation(:bike_was_added)
        redirect_to edit_bike_url(@bike)
      end
    else
      flash[:error] = "Unable to verify request, please sign in again"
      redirect_back(fallback_location: user_root_url)
    end
  end

  def edit
    @page_errors = @bike.errors
    @edit_templates = edit_templates
    @permitted_return_to = permitted_return_to
    requested_page = target_edit_template(requested_page: params[:page])
    @edit_template = requested_page[:template]
    unless requested_page[:is_valid]
      redirect_to(edit_bike_url(@bike, page: @edit_template)) && return
    end

    @skip_general_alert = %w[photos theft_details report_recovered remove].include?(@edit_template)
    case @edit_template
    when "photos"
      @private_images =
        PublicImage
          .unscoped
          .where(imageable_type: "Bike")
          .where(imageable_id: @bike.id)
          .where(is_private: true)
    when /alert/
      unless @bike&.current_stolen_record.present?
        redirect_to(edit_bike_url(@bike, page: @edit_template)) && return
      end
      @skip_general_alert = true
      bike_image = PublicImage.find_by(id: params[:selected_bike_image_id])
      @bike.current_stolen_record.generate_alert_image(bike_image: bike_image)

      @theft_alert_plans = TheftAlertPlan.active.price_ordered_asc.in_language(I18n.locale)
      @selected_theft_alert_plan =
        @theft_alert_plans.find_by(id: params[:selected_plan_id]) ||
        @theft_alert_plans.min_by(&:amount_cents)

      @theft_alerts =
        @bike
          .current_stolen_record
          .theft_alerts
          .includes(:theft_alert_plan)
          .creation_ordered_desc
          .where(user: current_user)
          .references(:theft_alert_plan)
    end

    render "edit_#{@edit_template}".to_sym
  end

  def update
    if params[:bike].present?
      begin
        @bike = BikeUpdator.new(user: current_user, bike: @bike, b_params: permitted_bike_params.as_json, current_ownership: @current_ownership).update_available_attributes
      rescue => e
        flash[:error] = e.message
        # Sometimes, weird things error. In production, Don't show a 500 page to the user
        # ... but in testing or development re-raise error to make stack tracing better
        raise e unless Rails.env.production?
      end
    end
    if ParamsNormalizer.boolean(params[:organization_ids_can_edit_claimed_present]) || params.key?(:organization_ids_can_edit_claimed)
      update_organizations_can_edit_claimed(@bike, params[:organization_ids_can_edit_claimed])
    end
    assign_bike_stickers(params[:bike_sticker]) if params[:bike_sticker].present?
    @bike = @bike.reload.decorate

    if @bike.errors.any? || flash[:error].present?
      @edit_templates = nil # So when we render edit it includes templates if the bike state has changed
      edit && return
    else
      flash[:success] ||= translation(:bike_was_updated)
      return if return_to_if_present
      redirect_to(edit_bike_url(@bike, page: params[:edit_template])) && return
    end
  end

  def edit_templates
    return @edit_templates if @edit_templates.present?
    @theft_templates = @bike.status_stolen? ? theft_templates : {}
    @bike_templates = bike_templates
    @edit_templates = @theft_templates.merge(@bike_templates)
  end

  def resolve_token
    if params[:token_type] == "graduated_notification"
      matching_notification = GraduatedNotification.where(bike_id: @bike.id, marked_remaining_link_token: params[:token]).first
      if matching_notification.present? && matching_notification.processed?
        flash[:success] = translation(:marked_remaining, bike_type: @bike.type)
        matching_notification.mark_remaining! unless matching_notification.marked_remaining?
      else
        flash[:error] = translation(:unable_to_find_graduated_notification)
      end
    else
      matching_notification = @bike.parking_notifications.where(retrieval_link_token: params[:token]).first
      if matching_notification.present?
        if matching_notification.active?
          flash[:success] = translation(:marked_retrieved, bike_type: @bike.type)
          # Quick hack to skip making another endpoint
          retrieved_kind = params[:user_recovery].present? ? "user_recovery" : "link_token_recovery"
          matching_notification.mark_retrieved!(retrieved_by_id: current_user&.id, retrieved_kind: retrieved_kind)
        elsif matching_notification.impounded? || matching_notification.impound_record_id.present?
          flash[:error] = translation(:notification_impounded, bike_type: @bike.type, org_name: matching_notification.organization.short_name)
        else
          # It's probably marked retrieved - but it could be something else (status: resolved_otherwise)
          flash[:info] = translation(:notification_already_retrieved, bike_type: @bike.type)
        end
      else
        flash[:error] = translation(:unable_to_find_parking_notification)
      end
    end

    redirect_to bike_path(@bike.id)
  end

  protected

  # Determine the appropriate edit template to use in the edit view.
  #
  # If provided an invalid template name, return the default page for a stolen /
  # unstolen bike and `:is_valid` mapped to false.
  #
  # Return a Hash with keys :is_valid (boolean), :template (string)
  def target_edit_template(requested_page:)
    result = {}
    valid_pages = [*edit_templates.keys, "alert_purchase", "alert_purchase_confirmation"]
    default_page = @bike.status_stolen? ? :theft_details : :bike_details

    if requested_page.blank?
      result[:is_valid] = true
      result[:template] = default_page.to_s
    elsif requested_page.in?(valid_pages)
      result[:is_valid] = true
      result[:template] = requested_page.to_s
    else
      result[:is_valid] = false
      result[:template] = default_page.to_s
    end

    result
  end

  # NB: Hash insertion order here determines how nav links are displayed in the
  # UI. Keys also correspond to template names and query parameters, and values
  # are used as haml header tag text in the corresponding templates.
  def theft_templates
    {}.with_indifferent_access.tap do |h|
      h[:theft_details] = translation(:theft_details, controller_method: :edit)
      h[:publicize] = translation(:publicize, controller_method: :edit)
      h[:alert] = translation(:alert, controller_method: :edit)
      h[:report_recovered] = translation(:report_recovered, controller_method: :edit)
    end
  end

  # NB: Hash insertion order here determines how nav links are displayed in the
  # UI. Keys also correspond to template names and query parameters, and values
  # are used as haml header tag text in the corresponding templates.
  def bike_templates
    {}.with_indifferent_access.tap do |h|
      h[:bike_details] = translation(:bike_details, controller_method: :edit)
      h[:found_details] = translation(:found_details, controller_method: :edit) if @bike.status_found?
      h[:photos] = translation(:photos, controller_method: :edit)
      h[:drivetrain] = translation(:drivetrain, controller_method: :edit)
      h[:accessories] = translation(:accessories, controller_method: :edit)
      h[:ownership] = translation(:ownership, controller_method: :edit)
      h[:groups] = translation(:groups, controller_method: :edit)
      h[:remove] = translation(:remove, controller_method: :edit)
      unless @bike.status_stolen_or_impounded?
        h[:report_stolen] = translation(:report_stolen, controller_method: :edit)
      end
    end
  end

  # Make it possible to assign organization for a view by passing the organization_id parameter - mainly useful for superusers
  # Also provides testable protection against seeing organization info on bikes
  def assign_current_organization
    org = current_organization || passive_organization # actually call #current_organization first
    # If forced false, or no user present, skip everything else
    return true if @current_organization_force_blank || current_user.blank?
    # If there was an organization_id passed, and the user isn't authorized for that org, reset passive_organization to something they can access
    # ... Particularly relevant for scanned stickers, which may be scanned by child orgs - but I think it's the behavior users expect regardless
    if current_user.default_organization.present? && params[:organization_id].present?
      return true if org.present? && current_user.authorized?(org)
      set_passive_organization(current_user.default_organization)
    else
      # If current_user isn't authorized for the organization, force assign nil
      return true if org.blank? || org.present? && current_user.authorized?(org)
      set_passive_organization(nil)
    end
  end

  def permitted_search_params
    params.permit(*Bike.permitted_search_params)
  end

  def find_bike
    begin
      @bike = Bike.unscoped.find(params[:id])
    rescue ActiveRecord::StatementInvalid => e
      raise e.to_s.match?(/PG..NumericValueOutOfRange/) ? ActiveRecord::RecordNotFound : e
    end
    if @bike.hidden || @bike.deleted?
      return @bike if current_user.present? && @bike.visible_by?(current_user)
      fail ActiveRecord::RecordNotFound
    end
  end

  def find_or_new_b_param
    token = params[:b_param_token]
    token ||= params.dig(:bike, :b_param_id_token)
    @b_param = BParam.find_or_new_from_token(token, user_id: current_user&.id)
  end

  def ensure_user_allowed_to_edit
    @current_ownership = @bike.current_ownership
    type = @bike&.type || "bike"

    return true if @bike.authorize_and_claim_for_user(current_user)

    if @bike.current_impound_record.present?
      error = if @bike.current_impound_record.organized?
        translation(:bike_impounded_by_organization, bike_type: type, org_name: @bike.current_impound_record.organization.name)
      else
        translation(:bike_impounded, bike_type: type)
      end
    elsif current_user.present?
      error = translation(:you_dont_own_that, bike_type: type)
    else
      store_return_to
      error = if @current_ownership && @bike.current_ownership.claimed
        translation(:you_have_to_sign_in, bike_type: type)
      else
        translation(:bike_has_not_been_claimed_yet, bike_type: type)
      end
    end

    return true unless error.present? # Can't assign directly to flash here, sometimes kick out of edit because other flash error
    flash[:error] = error
    redirect_to(bike_path(@bike)) && return
  end

  def update_organizations_can_edit_claimed(bike, organization_ids)
    organization_ids = Array(organization_ids).map(&:to_i)
    bike.bike_organizations.each do |bike_organization|
      bike_organization.update_attribute :can_not_edit_claimed, !organization_ids.include?(bike_organization.organization_id)
    end
  end

  def assign_bike_stickers(bike_sticker)
    bike_sticker = BikeSticker.lookup_with_fallback(bike_sticker)
    return flash[:error] = translation(:unable_to_find_sticker, bike_sticker: bike_sticker) unless bike_sticker.present?
    bike_sticker.claim_if_permitted(user: current_user, bike: @bike)
    if bike_sticker.errors.any?
      flash[:error] = bike_sticker.errors.full_messages
    else
      flash[:success] = translation(:sticker_assigned, bike_sticker: bike_sticker.pretty_code, bike_type: @bike.type)
    end
  end

  def find_token
    # First, deal with claim_token
    if params[:t].present? && @bike.current_ownership.token == params[:t]
      @claim_message = @bike.current_ownership&.claim_message
    end
    # Then deal with parking notification and graduated notification tokens
    @token = params[:parking_notification_retrieved].presence || params[:graduated_notification_remaining].presence
    return false if @token.blank?
    if params[:parking_notification_retrieved].present?
      @matching_notification = @bike.parking_notifications.where(retrieval_link_token: @token).first
      @token_type = @matching_notification&.kind
    elsif params[:graduated_notification_remaining].present?
      @matching_notification = GraduatedNotification.where(bike_id: @bike.id, marked_remaining_link_token: @token).first
      @token_type = "graduated_notification"
    end
    @token_type ||= "parked_incorrectly_notification" # Fallback
  end

  def render_ad
    @ad = true
  end

  def scanned_id
    params[:id] || params[:scanned_id] || params[:card_id]
  end

  def remove_subdomain
    redirect_to bikes_url(subdomain: false) if request.subdomain.present?
  end

  def permitted_bike_params
    {bike: params.require(:bike).permit(BikeCreator.old_attr_accessible)}
  end

  # still manually managing permission of params, so skip it
  def permitted_bparams
    params.except(:parking_notification).as_json # We only want to include parking_notification in authorized endpoints
  end
end
